#requires -Version 5.1
<#
.SYNOPSIS
Bootstraps PwrTest and runs Forcys laptop/desktop power stability tests.

.DESCRIPTION
Downloads NuGet.exe when needed, installs the Microsoft Windows WDK x64 NuGet
package when needed, locates pwrtest.exe, stages it into the Forcys toolkit
folder, and optionally runs sleep, Modern Standby, and hibernation cycles.

The script is intentionally idempotent: existing downloads, packages, binaries,
and output folders are reused unless a Force switch is supplied.
#>

[CmdletBinding()]
param(
    [ValidateRange(0, 10000)]
    [int]$SleepCycles = 50,

    [ValidateRange(0, 10000)]
    [int]$HibernateCycles = 25,

    [ValidateRange(1, 86400)]
    [int]$AwakeSeconds = 120,

    [ValidateRange(1, 86400)]
    [int]$SleepSeconds = 60,

    [ValidateNotNullOrEmpty()]
    [string]$ToolsRoot = (Join-Path $env:ProgramData "Forcys\TestSuite"),

    [ValidateNotNullOrEmpty()]
    [string]$OutputRoot = (Join-Path $env:ProgramData "Forcys\TestSuite\PwrTest-Logs"),

    [ValidateNotNullOrEmpty()]
    [string]$NuGetUrl = "https://dist.nuget.org/win-x86-commandline/latest/nuget.exe",

    [ValidateNotNullOrEmpty()]
    [string]$NuGetSource = "https://api.nuget.org/v3/index.json",

    [ValidateNotNullOrEmpty()]
    [string]$WdkPackage = "Microsoft.Windows.WDK.x64",

    [string]$WdkPackageVersion,

    [switch]$SetupOnly,
    [switch]$SkipSleep,
    [switch]$SkipHibernate,
    [switch]$SkipAdminCheck,
    [switch]$ForceRedownloadNuGet,
    [switch]$ForceRedownloadWDK,
    [switch]$ForceInstallPwrTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Administrator {
    if (-not $SkipAdminCheck -and -not (Test-IsAdministrator)) {
        throw "Run PowerShell as Administrator, or pass -SkipAdminCheck for setup-only experiments in a writable ToolsRoot."
    }
}

function Assert-NativePowerShell {
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        throw "Run this script from 64-bit PowerShell. PwrTest ETW tracing is not supported from 32-bit PowerShell on 64-bit Windows."
    }
}

function Write-Section {
    param([Parameter(Mandatory)][string]$Text)

    Write-Host ""
    Write-Host "============================================================"
    Write-Host $Text
    Write-Host "============================================================"
}

function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Invoke-External {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [int[]]$AllowedExitCodes = @(0)
    )

    Write-Verbose ("Running: {0} {1}" -f $FilePath, ($Arguments -join " "))
    & $FilePath @Arguments
    $exitCode = $LASTEXITCODE

    if ($AllowedExitCodes -notcontains $exitCode) {
        throw "Command failed with exit code $exitCode`: $FilePath $($Arguments -join ' ')"
    }

    return $exitCode
}

function Invoke-OptionalExternal {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$Description,
        [int[]]$AllowedExitCodes = @(0)
    )

    try {
        Invoke-External -FilePath $FilePath -Arguments $Arguments -AllowedExitCodes $AllowedExitCodes | Out-Null
    }
    catch {
        Write-Warning "$Description failed: $($_.Exception.Message)"
    }
}

function Save-CommandOutput {
    param(
        [Parameter(Mandatory)][scriptblock]$Command,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Description
    )

    try {
        & $Command | Out-File -LiteralPath $Path -Encoding UTF8
    }
    catch {
        Write-Warning "$Description failed: $($_.Exception.Message)"
    }
}

function Ensure-Tls12 {
    if ([Net.ServicePointManager]::SecurityProtocol -notmatch "Tls12") {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
}

function Ensure-NuGet {
    param(
        [Parameter(Mandatory)][string]$NuGetExe,
        [Parameter(Mandatory)][string]$Url,
        [switch]$Force
    )

    Write-Section "Checking NuGet"

    if ((Test-Path -LiteralPath $NuGetExe) -and -not $Force) {
        Write-Host "NuGet already exists: $NuGetExe"
        return
    }

    Ensure-Directory -Path (Split-Path -Path $NuGetExe -Parent)
    Ensure-Tls12

    $tempFile = "$NuGetExe.download"
    if (Test-Path -LiteralPath $tempFile) {
        Remove-Item -LiteralPath $tempFile -Force
    }

    Write-Host "Downloading NuGet.exe from $Url"
    Invoke-WebRequest -Uri $Url -OutFile $tempFile -UseBasicParsing

    if (-not (Test-Path -LiteralPath $tempFile)) {
        throw "NuGet download failed. Temporary file was not created: $tempFile"
    }

    Move-Item -LiteralPath $tempFile -Destination $NuGetExe -Force
    Write-Host "NuGet ready: $NuGetExe"
}

function Test-NuGet {
    param([Parameter(Mandatory)][string]$NuGetExe)

    Write-Section "Testing NuGet"
    Invoke-External -FilePath $NuGetExe -Arguments @("help") | Out-Null
    Write-Host "NuGet starts successfully."
}

function Find-PwrTest {
    param([Parameter(Mandatory)][string]$SearchRoot)

    if (-not (Test-Path -LiteralPath $SearchRoot)) {
        return $null
    }

    $matches = Get-ChildItem -LiteralPath $SearchRoot -Filter "pwrtest.exe" -Recurse -ErrorAction SilentlyContinue
    if (-not $matches) {
        return $null
    }

    $preferred = $matches |
        Where-Object { $_.FullName -match "\\(x64|amd64)\\" } |
        Sort-Object FullName -Descending |
        Select-Object -First 1

    if ($preferred) {
        return $preferred.FullName
    }

    return ($matches | Sort-Object FullName -Descending | Select-Object -First 1).FullName
}

function Ensure-WdkPackage {
    param(
        [Parameter(Mandatory)][string]$NuGetExe,
        [Parameter(Mandatory)][string]$WdkRoot,
        [Parameter(Mandatory)][string]$PackageName,
        [Parameter(Mandatory)][string]$Source,
        [string]$PackageVersion,
        [switch]$Force
    )

    Write-Section "Checking WDK NuGet package"
    Ensure-Directory -Path $WdkRoot

    $existingPwrTest = Find-PwrTest -SearchRoot $WdkRoot
    if ($existingPwrTest -and -not $Force) {
        Write-Host "Existing PwrTest found in WDK cache: $existingPwrTest"
        return
    }

    if ($Force) {
        Write-Host "ForceRedownloadWDK selected. Clearing WDK cache."
        Get-ChildItem -LiteralPath $WdkRoot -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
    }

    $arguments = @("install", $PackageName, "-Source", $Source, "-NonInteractive", "-Verbosity", "normal", "-OutputDirectory", $WdkRoot)
    if ($PackageVersion) {
        $arguments += @("-Version", $PackageVersion)
    }

    Invoke-External -FilePath $NuGetExe -Arguments $arguments | Out-Null
}

function Ensure-PwrTestTool {
    param(
        [Parameter(Mandatory)][string]$SourcePwrTest,
        [Parameter(Mandatory)][string]$TargetPwrTest,
        [switch]$Force
    )

    Write-Section "Checking staged PwrTest"
    Ensure-Directory -Path (Split-Path -Path $TargetPwrTest -Parent)

    if ((Test-Path -LiteralPath $TargetPwrTest) -and -not $Force) {
        $sourceHash = (Get-FileHash -LiteralPath $SourcePwrTest -Algorithm SHA256).Hash
        $targetHash = (Get-FileHash -LiteralPath $TargetPwrTest -Algorithm SHA256).Hash

        if ($sourceHash -eq $targetHash) {
            Write-Host "PwrTest is already staged: $TargetPwrTest"
            return
        }
    }

    Copy-Item -LiteralPath $SourcePwrTest -Destination $TargetPwrTest -Force
    Write-Host "PwrTest staged: $TargetPwrTest"
}

function Test-PwrTestSignature {
    param([Parameter(Mandatory)][string]$PwrTestExe)

    Write-Section "Checking PwrTest signature"
    $signature = Get-AuthenticodeSignature -LiteralPath $PwrTestExe
    $signature | Format-List Status, StatusMessage, SignerCertificate, Path

    if ($signature.Status -ne "Valid") {
        Write-Warning "The PwrTest signature is not valid. Verify the binary before using it on customer systems."
    }
}

function New-TestRoot {
    param([Parameter(Mandatory)][string]$BaseRoot)

    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $root = Join-Path $BaseRoot "Forcys-PwrTest-$stamp"

    foreach ($folder in @($root, "$root\Reports", "$root\EventLogs", "$root\PwrTest", "$root\Dumps")) {
        Ensure-Directory -Path $folder
    }

    return $root
}

function Export-Baseline {
    param([Parameter(Mandatory)][string]$Root)

    Write-Section "Collecting baseline"
    Save-CommandOutput -Command { powercfg /a } -Path "$Root\Reports\powercfg-a.txt" -Description "powercfg /a"
    Save-CommandOutput -Command { powercfg /requests } -Path "$Root\Reports\powercfg-requests-before.txt" -Description "powercfg /requests"
    Save-CommandOutput -Command { Get-ComputerInfo } -Path "$Root\Reports\computerinfo.txt" -Description "Get-ComputerInfo"
    Save-CommandOutput -Command { Get-CimInstance Win32_BIOS | Format-List * } -Path "$Root\Reports\bios.txt" -Description "BIOS inventory"
    Save-CommandOutput -Command { Get-CimInstance Win32_ComputerSystem | Format-List * } -Path "$Root\Reports\computersystem.txt" -Description "computer system inventory"
    Save-CommandOutput -Command { Get-CimInstance Win32_Processor | Format-List * } -Path "$Root\Reports\processor.txt" -Description "processor inventory"
    Save-CommandOutput -Command { Get-CimInstance Win32_PhysicalMemory | Format-List * } -Path "$Root\Reports\memory.txt" -Description "memory inventory"
    Save-CommandOutput -Command { Get-CimInstance Win32_DiskDrive | Format-List * } -Path "$Root\Reports\diskdrives.txt" -Description "disk inventory"
    Save-CommandOutput -Command { Get-PnpDevice | Sort-Object Class, FriendlyName } -Path "$Root\Reports\pnpdevices-before.txt" -Description "PnP inventory"
    Save-CommandOutput -Command { driverquery /v /fo csv } -Path "$Root\Reports\driverquery.csv" -Description "driverquery"

    Invoke-OptionalExternal -FilePath "powercfg.exe" -Arguments @("/batteryreport", "/output", "$Root\Reports\batteryreport.html") -Description "battery report"
    Invoke-OptionalExternal -FilePath "powercfg.exe" -Arguments @("/energy", "/duration", "120", "/output", "$Root\Reports\energy-before.html") -Description "energy report before"
    Invoke-OptionalExternal -FilePath "powercfg.exe" -Arguments @("/sleepstudy", "/output", "$Root\Reports\sleepstudy-before.html") -Description "sleep study before"
    Invoke-OptionalExternal -FilePath "powercfg.exe" -Arguments @("/systemsleepdiagnostics", "/output", "$Root\Reports\systemsleepdiagnostics-before.html") -Description "system sleep diagnostics before"
    Invoke-OptionalExternal -FilePath "msinfo32.exe" -Arguments @("/nfo", "$Root\Reports\msinfo32.nfo") -Description "msinfo32 export"
}

function Export-EventLogs {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Stage
    )

    Write-Section "Exporting event logs: $Stage"

    $logs = @(
        "System",
        "Application",
        "Microsoft-Windows-Diagnostics-Performance/Operational",
        "Microsoft-Windows-Power-Troubleshooter/Operational",
        "Microsoft-Windows-Kernel-Boot/Operational",
        "Microsoft-Windows-Kernel-Power/Thermal-Operational"
    )

    foreach ($log in $logs) {
        $safeName = $log -replace "[\\/:]", "_"
        Invoke-OptionalExternal -FilePath "wevtutil.exe" -Arguments @("epl", $log, "$Root\EventLogs\$Stage-$safeName.evtx") -Description "event log export for $log"
    }

    Save-CommandOutput -Command {
        Get-WinEvent -LogName System -MaxEvents 500 |
            Where-Object {
                $_.ProviderName -match "Kernel-Power|WHEA|Display|BugCheck|Power-Troubleshooter|USB|ACPI|Intel|Thunderbolt|stornvme|iaStor|Netwtw"
            } |
            Select-Object TimeCreated, ProviderName, Id, LevelDisplayName, Message |
            Format-List
    } -Path "$Root\EventLogs\$Stage-interesting-system-events.txt" -Description "interesting system event export"
}

function Copy-Dumps {
    param([Parameter(Mandatory)][string]$Root)

    Write-Section "Copying crash dumps"

    if (Test-Path -LiteralPath "C:\Windows\Minidump") {
        Copy-Item -Path "C:\Windows\Minidump\*.dmp" -Destination "$Root\Dumps" -ErrorAction SilentlyContinue
    }

    if (Test-Path -LiteralPath "C:\Windows\MEMORY.DMP") {
        Copy-Item -LiteralPath "C:\Windows\MEMORY.DMP" -Destination "$Root\Dumps" -ErrorAction SilentlyContinue
    }
}

function Get-PowerStateInfo {
    param([Parameter(Mandatory)][string]$Root)

    Write-Section "Detecting power states"
    $states = powercfg /a | Out-String
    $states | Out-File -LiteralPath "$Root\Reports\power-states.txt" -Encoding UTF8
    Write-Host $states

    return [pscustomobject]@{
        HasS3 = $states -match "\bS3\b"
        HasS4 = $states -match "\bS4\b|Hibernate|Sluimerstand"
        HasS0 = $states -match "S0 Low Power Idle|Modern Standby|Moderne stand-by|Stand-by \(S0|Connected Standby"
        Raw = $states
    }
}

function Invoke-PwrTestRuns {
    param(
        [Parameter(Mandatory)][string]$PwrTestExe,
        [Parameter(Mandatory)][string]$Root,
        [int]$SleepCycleCount,
        [int]$HibernateCycleCount,
        [int]$AwakeDurationSeconds,
        [int]$SleepDurationSeconds,
        [switch]$NoSleep,
        [switch]$NoHibernate
    )

    $stateInfo = Get-PowerStateInfo -Root $Root

    if (-not $NoSleep -and $SleepCycleCount -gt 0) {
        if ($stateInfo.HasS3) {
            Write-Section "Starting S3 sleep test"
            Invoke-External -FilePath $PwrTestExe -Arguments @("/sleep", "/c:$SleepCycleCount", "/s:3", "/d:$AwakeDurationSeconds", "/p:$SleepDurationSeconds", "/unattend", "/lf:$Root\PwrTest", "/ln:sleep-s3") | Out-Null
        }
        elseif ($stateInfo.HasS0) {
            Write-Section "Starting Modern Standby test"
            Invoke-External -FilePath $PwrTestExe -Arguments @("/cs", "/c:$SleepCycleCount", "/d:$AwakeDurationSeconds", "/p:$SleepDurationSeconds", "/lf:$Root\PwrTest", "/ln:connected-standby") | Out-Null
        }
        else {
            Write-Warning "No clear S3 or Modern Standby support detected. Sleep test skipped."
        }
    }

    if (-not $NoHibernate -and $HibernateCycleCount -gt 0) {
        if (-not $stateInfo.HasS4) {
            Write-Host "Hibernate/S4 is not currently reported as available. Trying to enable hibernation."
            Invoke-OptionalExternal -FilePath "powercfg.exe" -Arguments @("/hibernate", "on") -Description "enable hibernation"
            Start-Sleep -Seconds 2
        }

        Write-Section "Starting S4 hibernate test"
        Invoke-External -FilePath $PwrTestExe -Arguments @("/sleep", "/c:$HibernateCycleCount", "/s:4", "/d:$AwakeDurationSeconds", "/p:$SleepDurationSeconds", "/unattend", "/lf:$Root\PwrTest", "/ln:hibernate-s4") | Out-Null
    }
}

function Export-AfterReports {
    param([Parameter(Mandatory)][string]$Root)

    Write-Section "Collecting after-test reports"
    Save-CommandOutput -Command { powercfg /requests } -Path "$Root\Reports\powercfg-requests-after.txt" -Description "powercfg /requests after"
    Save-CommandOutput -Command { Get-PnpDevice | Sort-Object Class, FriendlyName } -Path "$Root\Reports\pnpdevices-after.txt" -Description "PnP inventory after"

    Invoke-OptionalExternal -FilePath "powercfg.exe" -Arguments @("/energy", "/duration", "120", "/output", "$Root\Reports\energy-after.html") -Description "energy report after"
    Invoke-OptionalExternal -FilePath "powercfg.exe" -Arguments @("/sleepstudy", "/output", "$Root\Reports\sleepstudy-after.html") -Description "sleep study after"
    Invoke-OptionalExternal -FilePath "powercfg.exe" -Arguments @("/systemsleepdiagnostics", "/output", "$Root\Reports\systemsleepdiagnostics-after.html") -Description "system sleep diagnostics after"
}

function Write-TestReadme {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$PwrTestExe,
        [Parameter(Mandatory)][string]$PackageName,
        [string]$PackageVersion
    )

    $versionText = if ($PackageVersion) { $PackageVersion } else { "latest available at install time" }
    $readme = @"
Forcys PwrTest / Power Stability Test

Date:
$(Get-Date -Format "yyyy-MM-dd HH:mm:ss zzz")

PwrTest:
$PwrTestExe

WDK package:
$PackageName

WDK package version:
$versionText

Output folder:
$Root

Important files:
- Reports\powercfg-a.txt
- Reports\power-states.txt
- Reports\sleepstudy-before.html
- Reports\sleepstudy-after.html
- Reports\systemsleepdiagnostics-before.html
- Reports\systemsleepdiagnostics-after.html
- PwrTest\*.xml
- EventLogs\*.evtx
- EventLogs\*-interesting-system-events.txt
- Dumps\*.dmp if present

Interpretation:
- If all cycles complete, the issue was not reproduced during this run.
- Crash/freeze during sleep or resume: inspect BIOS, firmware, chipset, graphics, USB-C/dock, storage, and Modern Standby related drivers.
- WHEA events usually point toward hardware, firmware, PCIe, storage, or CPU platform issues.
- Display resets or black-screen resume issues often involve graphics, docks, external monitors, or the display path.
- Kernel-Power 41 without BugCheck usually means hard freeze or power loss.

Recommended customer-case follow-up:
1. Run the vendor update assistant and save its report.
2. Run firmware/UEFI extensive diagnostics, preferably as an overnight loop.
3. Keep this PwrTest output folder with the case.
4. Run a separate dock test with external display, ethernet, and USB devices attached.
"@

    $readme | Out-File -LiteralPath "$Root\README.txt" -Encoding UTF8
}

Assert-Administrator
Assert-NativePowerShell

$nuGetExe = Join-Path $ToolsRoot "NuGet\nuget.exe"
$wdkRoot = Join-Path $ToolsRoot "WDK-NuGet"
$pwrTestExe = Join-Path $ToolsRoot "PwrTest\pwrtest.exe"

Ensure-Directory -Path $ToolsRoot
Ensure-Directory -Path $OutputRoot

Write-Section "Forcys PwrTest setup"

Ensure-NuGet -NuGetExe $nuGetExe -Url $NuGetUrl -Force:$ForceRedownloadNuGet
Test-NuGet -NuGetExe $nuGetExe

Ensure-WdkPackage `
    -NuGetExe $nuGetExe `
    -WdkRoot $wdkRoot `
    -PackageName $WdkPackage `
    -Source $NuGetSource `
    -PackageVersion $WdkPackageVersion `
    -Force:$ForceRedownloadWDK

$foundPwrTest = Find-PwrTest -SearchRoot $wdkRoot
if (-not $foundPwrTest) {
    throw "pwrtest.exe was not found under $wdkRoot after installing $WdkPackage."
}

Ensure-PwrTestTool -SourcePwrTest $foundPwrTest -TargetPwrTest $pwrTestExe -Force:$ForceInstallPwrTest
Test-PwrTestSignature -PwrTestExe $pwrTestExe

Write-Section "PwrTest help check"
Invoke-OptionalExternal -FilePath $pwrTestExe -Arguments @("/?") -Description "PwrTest help check"

if ($SetupOnly) {
    Write-Host ""
    Write-Host "SetupOnly selected. PwrTest is ready:"
    Write-Host $pwrTestExe
    return
}

$testRoot = New-TestRoot -BaseRoot $OutputRoot
$transcriptStarted = $false

try {
    Start-Transcript -Path "$testRoot\transcript.txt" -Force | Out-Null
    $transcriptStarted = $true

    Write-Section "Test output"
    Write-Host $testRoot

    Export-Baseline -Root $testRoot
    Export-EventLogs -Root $testRoot -Stage "before"

    Invoke-PwrTestRuns `
        -PwrTestExe $pwrTestExe `
        -Root $testRoot `
        -SleepCycleCount $SleepCycles `
        -HibernateCycleCount $HibernateCycles `
        -AwakeDurationSeconds $AwakeSeconds `
        -SleepDurationSeconds $SleepSeconds `
        -NoSleep:$SkipSleep `
        -NoHibernate:$SkipHibernate

    Export-AfterReports -Root $testRoot
    Export-EventLogs -Root $testRoot -Stage "after"
    Copy-Dumps -Root $testRoot

    Write-TestReadme `
        -Root $testRoot `
        -PwrTestExe $pwrTestExe `
        -PackageName $WdkPackage `
        -PackageVersion $WdkPackageVersion

    Write-Section "Done"
    Write-Host "PwrTest toolkit:"
    Write-Host $pwrTestExe
    Write-Host ""
    Write-Host "Output:"
    Write-Host $testRoot
    Write-Host ""
    Write-Host "Open:"
    Write-Host "$testRoot\README.txt"
}
finally {
    if ($transcriptStarted) {
        Stop-Transcript | Out-Null
    }
}
