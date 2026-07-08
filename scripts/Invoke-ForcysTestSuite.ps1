#requires -Version 5.1
<#
.SYNOPSIS
Runs the Forcys Test Suite and creates a zipped evidence bundle.

.DESCRIPTION
This is the suite-level orchestrator. It runs individual diagnostic modules in
separate PowerShell processes so one failing or unsupported module does not
prevent the rest of the collection from completing. Every module gets a log,
the run gets a manifest, and the final output is a zip file that can be attached
to a customer case.
#>

[CmdletBinding()]
param(
    [ValidateSet("Quick", "Triage", "Full")]
    [string]$Profile = "Triage",

    [ValidateNotNullOrEmpty()]
    [string]$InstallRoot = (Split-Path -Path $PSScriptRoot -Parent),

    [ValidateNotNullOrEmpty()]
    [string]$ToolsRoot = (Join-Path $env:ProgramData "Forcys\TestSuite"),

    [ValidateNotNullOrEmpty()]
    [string]$OutputRoot = (Join-Path $env:ProgramData "Forcys\TestSuite\Runs"),

    [ValidateRange(1, 365)]
    [int]$LookbackDays = 7,

    [ValidateRange(0, 10000)]
    [int]$SleepCycles = 2,

    [ValidateRange(0, 10000)]
    [int]$HibernateCycles = 1,

    [ValidateRange(1, 86400)]
    [int]$AwakeSeconds = 60,

    [ValidateRange(1, 86400)]
    [int]$SleepSeconds = 30,

    [ValidateRange(10, 3600)]
    [int]$EnergyDurationSeconds = 120,

    [string]$DebuggerPath,

    [switch]$InstallTools,
    [switch]$InstallFullWDK,
    [switch]$InstallWdtf,
    [switch]$SkipPwrTest,
    [switch]$SkipKernelPower,
    [switch]$SkipEnergyReport,
    [switch]$SkipDumpAnalysis,
    [switch]$ConfigureMinidumps,
    [switch]$KeepUnzipped
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Section {
    param([Parameter(Mandatory)][string]$Text)

    Write-Host ""
    Write-Host "============================================================"
    Write-Host $Text
    Write-Host "============================================================"
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Join-PathSafe {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$ChildPath
    )

    $current = $Path
    foreach ($child in $ChildPath) {
        $current = Join-Path -Path $current -ChildPath $child
    }

    return $current
}

function Resolve-DirectoryPath {
    param([Parameter(Mandatory)][string]$Path)

    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if ($resolved -match "^[A-Za-z]:$") {
        return "$resolved\"
    }

    return $resolved
}

function Save-Json {
    param(
        [Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)][string]$Path
    )

    $InputObject | ConvertTo-Json -Depth 10 | Out-File -LiteralPath $Path -Encoding UTF8
}

function Get-ForcysPreflight {
    param(
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][string]$ToolsRoot,
        [Parameter(Mandatory)][string]$OutputRoot
    )

    $commands = @(
        "powercfg.exe",
        "wevtutil.exe",
        "msinfo32.exe",
        "driverquery.exe",
        "chkdsk.exe",
        "winget.exe",
        "cdb.exe"
    )

    $commandStatus = foreach ($command in $commands) {
        $found = Get-Command $command -ErrorAction SilentlyContinue
        [pscustomobject]@{
            Name  = $command
            Found = [bool]$found
            Path  = if ($found) { $found.Source } else { $null }
        }
    }

    $drive = $null
    try {
        $driveRoot = ([System.IO.DirectoryInfo]$OutputRoot).Root.Name.TrimEnd("\")
        $drive = Get-PSDrive -Name $driveRoot.TrimEnd(":") -ErrorAction SilentlyContinue
    }
    catch {
    }

    $powerStates = $null
    try {
        $powerStates = (powercfg /a) -join [Environment]::NewLine
    }
    catch {
        $powerStates = "powercfg /a failed: $($_.Exception.Message)"
    }

    return [pscustomobject]@{
        CapturedAt        = Get-Date
        IsAdministrator   = Test-IsAdministrator
        Is64BitProcess    = [Environment]::Is64BitProcess
        Is64BitOS         = [Environment]::Is64BitOperatingSystem
        OSVersion         = [Environment]::OSVersion.VersionString
        ComputerName      = $env:COMPUTERNAME
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        RunRoot           = $RunRoot
        ToolsRoot         = $ToolsRoot
        OutputRoot        = $OutputRoot
        OutputDriveFreeGB = if ($drive) { [math]::Round($drive.Free / 1GB, 2) } else { $null }
        Commands          = @($commandStatus)
        PowerStates       = $powerStates
    }
}

function Add-Argument {
    param(
        [System.Collections.Generic.List[string]]$Arguments,
        [Parameter(Mandatory)][string]$Name,
        [object]$Value
    )

    $Arguments.Add($Name) | Out-Null
    if ($null -ne $Value) {
        $Arguments.Add([string]$Value) | Out-Null
    }
}

function Add-SwitchArgument {
    param(
        [System.Collections.Generic.List[string]]$Arguments,
        [Parameter(Mandatory)][string]$Name,
        [bool]$Enabled
    )

    if ($Enabled) {
        $Arguments.Add($Name) | Out-Null
    }
}

function Invoke-SuiteModule {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string[]]$ScriptArguments,
        [Parameter(Mandatory)][string]$LogsRoot
    )

    $startedAt = Get-Date
    $safeName = $Name -replace "[^A-Za-z0-9_.-]", "_"
    $logPath = Join-PathSafe -Path $LogsRoot -ChildPath @("$safeName.log")
    $arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $ScriptPath) + $ScriptArguments

    Write-Section "Running module: $Name"
    Write-Host "Log: $logPath"

    $exitCode = $null
    $status = "Succeeded"
    $errorMessage = $null

    try {
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            & powershell.exe @arguments *> $logPath
            $exitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }

        if ($exitCode -ne 0) {
            $status = "Failed"
            $errorMessage = "Module exited with code $exitCode."
            Write-Warning "$Name failed with exit code $exitCode. Continuing with remaining modules."
        }
    }
    catch {
        $status = "Failed"
        $errorMessage = $_.Exception.Message
        "Module launcher failed: $errorMessage" | Out-File -LiteralPath $logPath -Encoding UTF8 -Append
        Write-Warning "$Name failed: $errorMessage"
    }

    $finishedAt = Get-Date
    return [pscustomobject]@{
        Name          = $Name
        Script        = $ScriptPath
        Arguments     = $ScriptArguments
        Status        = $status
        ExitCode      = $exitCode
        StartedAt     = $startedAt
        FinishedAt    = $finishedAt
        DurationSec   = [math]::Round(($finishedAt - $startedAt).TotalSeconds, 2)
        LogPath       = $logPath
        ErrorMessage  = $errorMessage
    }
}

function Write-RunReadme {
    param(
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)]$Manifest
    )

    $moduleLines = foreach ($module in $Manifest.Modules) {
        "- $($module.Name): $($module.Status), exit code $($module.ExitCode), log $($module.LogPath)"
    }

    $content = @"
Forcys Test Suite Run

Profile:
$($Manifest.Profile)

Started:
$($Manifest.StartedAt)

Finished:
$($Manifest.FinishedAt)

Administrator:
$($Manifest.IsAdministrator)

Machine:
$($Manifest.ComputerName)

Windows:
$($Manifest.WindowsVersion)

Run folder:
$RunRoot

Zip bundle:
$ZipPath

Modules:
$($moduleLines -join [Environment]::NewLine)

Start here:
1. Review RunManifest.json for module status.
2. Review Logs\*.log for module console output.
3. Review Modules\KernelPower\*\Reports\interesting-events.csv for crash, WHEA, display, storage, and power events.
4. Review Modules\PwrTest\*\README.txt and PwrTest XML/log output when PwrTest ran.
5. Attach the zip bundle to the support case.
"@

    $content | Out-File -LiteralPath (Join-PathSafe -Path $RunRoot -ChildPath @("README.txt")) -Encoding UTF8
}

$installRootPath = Resolve-DirectoryPath -Path $InstallRoot
$outputRootPath = Resolve-DirectoryPath -Path $OutputRoot
$toolsRootPath = Resolve-DirectoryPath -Path $ToolsRoot
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$runRoot = Join-Path -Path $outputRootPath -ChildPath "Forcys-TestSuite-$stamp"
$logsRoot = Join-PathSafe -Path $runRoot -ChildPath @("Logs")
$modulesRoot = Join-PathSafe -Path $runRoot -ChildPath @("Modules")
$zipPath = Join-Path -Path $outputRootPath -ChildPath "Forcys-TestSuite-$stamp.zip"

Ensure-Directory -Path $outputRootPath
Ensure-Directory -Path $runRoot
Ensure-Directory -Path $logsRoot
Ensure-Directory -Path $modulesRoot
Ensure-Directory -Path $toolsRootPath

$suiteStartedAt = Get-Date
$isAdministrator = Test-IsAdministrator

Write-Section "Forcys Test Suite"
Write-Host "Profile: $Profile"
Write-Host "Run folder: $runRoot"
Write-Host "Administrator: $isAdministrator"

if (-not $isAdministrator) {
    Write-Warning "This run is not elevated. Some reports, crash configuration, WDK/WDTF setup, and power-state tests may fail or skip."
}

$modules = New-Object System.Collections.Generic.List[object]
$preflight = Get-ForcysPreflight -RunRoot $runRoot -ToolsRoot $toolsRootPath -OutputRoot $outputRootPath
Save-Json -InputObject $preflight -Path (Join-PathSafe -Path $runRoot -ChildPath @("Preflight.json"))

if (-not $SkipKernelPower) {
    $kernelPowerScript = Join-PathSafe -Path $installRootPath -ChildPath @("scripts", "Invoke-ForcysKernelPowerCollect.ps1")
    if (Test-Path -LiteralPath $kernelPowerScript) {
        $arguments = New-Object System.Collections.Generic.List[string]
        Add-Argument -Arguments $arguments -Name "-OutputRoot" -Value (Join-PathSafe -Path $modulesRoot -ChildPath @("KernelPower"))
        Add-Argument -Arguments $arguments -Name "-LookbackDays" -Value $LookbackDays
        Add-Argument -Arguments $arguments -Name "-EnergyDurationSeconds" -Value $EnergyDurationSeconds
        Add-Argument -Arguments $arguments -Name "-SymbolCache" -Value (Join-PathSafe -Path $toolsRootPath -ChildPath @("Symbols"))
        if ($DebuggerPath) {
            Add-Argument -Arguments $arguments -Name "-DebuggerPath" -Value $DebuggerPath
        }
        Add-SwitchArgument -Arguments $arguments -Name "-SkipEnergyReport" -Enabled ([bool]$SkipEnergyReport -or $Profile -eq "Quick")
        Add-SwitchArgument -Arguments $arguments -Name "-SkipDumpAnalysis" -Enabled ([bool]$SkipDumpAnalysis -or $Profile -eq "Quick")
        Add-SwitchArgument -Arguments $arguments -Name "-SkipStorageScan" -Enabled ($Profile -eq "Quick")
        Add-SwitchArgument -Arguments $arguments -Name "-ConfigureMinidumps" -Enabled ([bool]$ConfigureMinidumps)

        $modules.Add((Invoke-SuiteModule -Name "KernelPower" -ScriptPath $kernelPowerScript -ScriptArguments $arguments.ToArray() -LogsRoot $logsRoot)) | Out-Null
    }
    else {
        Write-Warning "KernelPower script was not found: $kernelPowerScript"
    }
}

if (-not $SkipPwrTest) {
    $pwrTestScript = Join-PathSafe -Path $installRootPath -ChildPath @("scripts", "Invoke-ForcysPwrTest.ps1")
    if (Test-Path -LiteralPath $pwrTestScript) {
        $arguments = New-Object System.Collections.Generic.List[string]
        Add-Argument -Arguments $arguments -Name "-ToolsRoot" -Value $toolsRootPath
        Add-Argument -Arguments $arguments -Name "-OutputRoot" -Value (Join-PathSafe -Path $modulesRoot -ChildPath @("PwrTest"))
        Add-Argument -Arguments $arguments -Name "-EnergyDurationSeconds" -Value $EnergyDurationSeconds
        Add-SwitchArgument -Arguments $arguments -Name "-InstallFullWDK" -Enabled ([bool]$InstallTools -and [bool]$InstallFullWDK)
        Add-SwitchArgument -Arguments $arguments -Name "-InstallWdtf" -Enabled ([bool]$InstallTools -and [bool]$InstallWdtf)
        Add-SwitchArgument -Arguments $arguments -Name "-SkipEnergyReport" -Enabled ([bool]$SkipEnergyReport -or $Profile -eq "Quick")

        if ($Profile -eq "Quick") {
            Add-Argument -Arguments $arguments -Name "-SleepCycles" -Value 0
            Add-Argument -Arguments $arguments -Name "-HibernateCycles" -Value 0
            Add-SwitchArgument -Arguments $arguments -Name "-SetupOnly" -Enabled $true
        }
        else {
            Add-Argument -Arguments $arguments -Name "-SleepCycles" -Value $SleepCycles
            Add-Argument -Arguments $arguments -Name "-HibernateCycles" -Value $HibernateCycles
            Add-Argument -Arguments $arguments -Name "-AwakeSeconds" -Value $AwakeSeconds
            Add-Argument -Arguments $arguments -Name "-SleepSeconds" -Value $SleepSeconds
        }

        $modules.Add((Invoke-SuiteModule -Name "PwrTest" -ScriptPath $pwrTestScript -ScriptArguments $arguments.ToArray() -LogsRoot $logsRoot)) | Out-Null
    }
    else {
        Write-Warning "PwrTest script was not found: $pwrTestScript"
    }
}

$suiteFinishedAt = Get-Date
$moduleResults = @($modules.ToArray())
$manifest = [pscustomobject]@{
    SuiteName       = "Forcys Test Suite"
    Profile         = $Profile
    StartedAt       = $suiteStartedAt
    FinishedAt      = $suiteFinishedAt
    DurationSec     = [math]::Round(($suiteFinishedAt - $suiteStartedAt).TotalSeconds, 2)
    ComputerName    = $env:COMPUTERNAME
    UserName        = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    IsAdministrator = $isAdministrator
    WindowsVersion  = [Environment]::OSVersion.VersionString
    InstallRoot     = $installRootPath
    ToolsRoot       = $toolsRootPath
    RunRoot         = $runRoot
    ZipPath         = $zipPath
    Preflight       = $preflight
    Modules         = $moduleResults
}

Save-Json -InputObject $manifest -Path (Join-PathSafe -Path $runRoot -ChildPath @("RunManifest.json"))
Write-RunReadme -RunRoot $runRoot -ZipPath $zipPath -Manifest $manifest

Write-Section "Creating zip bundle"
if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}
Compress-Archive -LiteralPath $runRoot -DestinationPath $zipPath -Force

if (-not $KeepUnzipped) {
    Write-Host "Unzipped run folder kept for review:"
    Write-Host $runRoot
}

Write-Section "Done"
Write-Host "Zip bundle:"
Write-Host $zipPath
Write-Host ""
Write-Host "Run manifest:"
Write-Host (Join-PathSafe -Path $runRoot -ChildPath @("RunManifest.json"))
