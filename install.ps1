#requires -Version 5.1
<#
.SYNOPSIS
Downloads or updates the Forcys Test Suite into a local folder.

.DESCRIPTION
This bootstrapper does not require Git. It downloads the repository ZIP from
GitHub, extracts it to a temporary folder, and copies the suite files into the
chosen install directory. Local tool caches and test output folders are left in
place.
#>

[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$InstallRoot = "C:\forcys-test-suite",

    [ValidateNotNullOrEmpty()]
    [string]$ToolsRoot = (Join-Path $env:ProgramData "Forcys\TestSuite"),

    [ValidateNotNullOrEmpty()]
    [string]$OutputRoot = (Join-Path $env:ProgramData "Forcys\TestSuite\Runs"),

    [ValidateNotNullOrEmpty()]
    [string]$RepositoryZipUrl = "https://github.com/Forcys/forcys-test-suite/archive/refs/heads/main.zip",

    [switch]$SetupPwrTest,
    [switch]$RunSuite,
    [ValidateSet("Quick", "Triage", "Full")]
    [string]$Profile = "Triage",
    [switch]$InstallFullWDK,
    [switch]$InstallWdtf,
    [switch]$Elevate,
    [switch]$CleanBackups
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

function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Resolve-DirectoryPath {
    param([Parameter(Mandatory)][string]$Path)

    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if ($resolved -match "^[A-Za-z]:$") {
        return "$resolved\"
    }

    return $resolved
}

function Ensure-Tls12 {
    if ([Net.ServicePointManager]::SecurityProtocol -notmatch "Tls12") {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Add-ProcessArgument {
    param(
        [System.Collections.Generic.List[string]]$Arguments,
        [Parameter(Mandatory)][string]$Name,
        [string]$Value
    )

    $Arguments.Add($Name) | Out-Null
    if ($null -ne $Value) {
        $Arguments.Add($Value) | Out-Null
    }
}

function Add-ProcessSwitch {
    param(
        [System.Collections.Generic.List[string]]$Arguments,
        [Parameter(Mandatory)][string]$Name,
        [bool]$Enabled
    )

    if ($Enabled) {
        $Arguments.Add($Name) | Out-Null
    }
}

function ConvertTo-ProcessArgumentLine {
    param([Parameter(Mandatory)][string[]]$Arguments)

    return (($Arguments | ForEach-Object {
        if ($_ -match '[\s"]') {
            '"' + ($_ -replace '"', '\"') + '"'
        }
        else {
            $_
        }
    }) -join " ")
}

function Start-ElevatedSelf {
    $arguments = [System.Collections.Generic.List[string]]::new()
    Add-ProcessArgument -Arguments $arguments -Name "-NoProfile" -Value $null
    Add-ProcessArgument -Arguments $arguments -Name "-ExecutionPolicy" -Value "Bypass"
    Add-ProcessArgument -Arguments $arguments -Name "-File" -Value $PSCommandPath
    Add-ProcessArgument -Arguments $arguments -Name "-InstallRoot" -Value (Resolve-DirectoryPath -Path $InstallRoot)
    Add-ProcessArgument -Arguments $arguments -Name "-ToolsRoot" -Value (Resolve-DirectoryPath -Path $ToolsRoot)
    Add-ProcessArgument -Arguments $arguments -Name "-OutputRoot" -Value (Resolve-DirectoryPath -Path $OutputRoot)
    Add-ProcessArgument -Arguments $arguments -Name "-RepositoryZipUrl" -Value $RepositoryZipUrl
    Add-ProcessArgument -Arguments $arguments -Name "-Profile" -Value $Profile
    Add-ProcessSwitch -Arguments $arguments -Name "-SetupPwrTest" -Enabled ([bool]$SetupPwrTest)
    Add-ProcessSwitch -Arguments $arguments -Name "-RunSuite" -Enabled ([bool]$RunSuite)
    Add-ProcessSwitch -Arguments $arguments -Name "-InstallFullWDK" -Enabled ([bool]$InstallFullWDK)
    Add-ProcessSwitch -Arguments $arguments -Name "-InstallWdtf" -Enabled ([bool]$InstallWdtf)
    Add-ProcessSwitch -Arguments $arguments -Name "-CleanBackups" -Enabled ([bool]$CleanBackups)

    Write-Section "Requesting elevation"
    Write-Host "A UAC prompt will open. The elevated process will continue the Forcys setup/run."

    $argumentLine = ConvertTo-ProcessArgumentLine -Arguments $arguments.ToArray()
    $process = Start-Process -FilePath "powershell.exe" -ArgumentList $argumentLine -Verb RunAs -Wait -PassThru
    exit $process.ExitCode
}

function Remove-ExistingRepoFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$BackupRoot
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $item = Get-Item -LiteralPath $Path -Force
    Ensure-Directory -Path $BackupRoot
    Move-Item -LiteralPath $Path -Destination (Join-Path $BackupRoot $item.Name) -Force
}

function Test-PreserveInstallItem {
    param([Parameter(Mandatory)][System.IO.FileSystemInfo]$Item)

    if ($Item.PSIsContainer) {
        return @(
            ".git",
            ".agents",
            ".codex",
            "tools",
            "Runs",
            "PwrTest-Logs",
            "KernelPower-Logs",
            "analysis",
            "Reports",
            "Dumps"
        ) -contains $Item.Name -or $Item.Name -like "*-Logs"
    }

    return $Item.Extension -in @(".zip", ".evtx", ".dmp", ".log")
}

if ($Elevate -and -not (Test-IsAdministrator)) {
    Start-ElevatedSelf
}

$installRootPath = Resolve-DirectoryPath -Path $InstallRoot
$toolsRootPath = Resolve-DirectoryPath -Path $ToolsRoot
$outputRootPath = Resolve-DirectoryPath -Path $OutputRoot
$tempRoot = Join-Path $env:TEMP ("forcys-test-suite-install-" + [guid]::NewGuid().ToString())
$zipPath = Join-Path $tempRoot "forcys-test-suite.zip"
$extractRoot = Join-Path $tempRoot "extract"
$backupRoot = Join-Path $installRootPath ("install-backups\" + (Get-Date -Format "yyyyMMdd-HHmmss"))

try {
    Write-Section "Forcys Test Suite download/update"
    Write-Host "Install root:"
    Write-Host $installRootPath

    Ensure-Directory -Path $tempRoot
    Ensure-Directory -Path $extractRoot
    Ensure-Directory -Path $installRootPath
    Ensure-Tls12

    Write-Section "Downloading repository"
    Write-Host $RepositoryZipUrl
    Invoke-WebRequest -Uri $RepositoryZipUrl -OutFile $zipPath -UseBasicParsing

    Write-Section "Extracting repository"
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractRoot -Force

    $sourceRoot = Get-ChildItem -LiteralPath $extractRoot -Directory | Select-Object -First 1
    if (-not $sourceRoot) {
        throw "The downloaded repository archive did not contain a source folder."
    }

    Write-Section "Updating files"
    foreach ($sourceItem in Get-ChildItem -LiteralPath $sourceRoot.FullName -Force) {
        if (Test-PreserveInstallItem -Item $sourceItem) {
            continue
        }

        $targetPath = Join-Path $installRootPath $sourceItem.Name
        if (Test-Path -LiteralPath $targetPath) {
            Remove-ExistingRepoFile -Path $targetPath -BackupRoot $backupRoot
        }

        Copy-Item -LiteralPath $sourceItem.FullName -Destination $targetPath -Recurse -Force
        Write-Host "Updated $($sourceItem.Name)"
    }

    if (Test-Path -LiteralPath $backupRoot) {
        Write-Host "Previous repo-managed files were backed up to:"
        Write-Host $backupRoot
        if ($CleanBackups) {
            Remove-Item -LiteralPath $backupRoot -Recurse -Force
            Write-Host "CleanBackups selected. Removed this run's backup folder."
        }
    }

    if ($SetupPwrTest) {
        Write-Section "Setting up PwrTest"
        $pwrTestScript = Join-Path $installRootPath "scripts\Invoke-ForcysPwrTest.ps1"
        if (-not (Test-Path -LiteralPath $pwrTestScript)) {
            throw "PwrTest script not found after update: $pwrTestScript"
        }

        $setupArguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $pwrTestScript, "-SetupOnly", "-ToolsRoot", $toolsRootPath, "-OutputRoot", (Join-Path $outputRootPath "PwrTest-Setup"))
        if ($InstallFullWDK) {
            $setupArguments += "-InstallFullWDK"
        }

        if ($InstallWdtf) {
            $setupArguments += "-InstallWdtf"
        }

        & powershell.exe @setupArguments
        if ($LASTEXITCODE -ne 0) {
            throw "PwrTest setup failed with exit code $LASTEXITCODE."
        }
    }

    if ($RunSuite) {
        Write-Section "Running Forcys Test Suite"
        $suiteScript = Join-Path $installRootPath "Invoke-Forcys.ps1"
        if (-not (Test-Path -LiteralPath $suiteScript)) {
            throw "Forcys suite entry point not found after update: $suiteScript"
        }

        $suiteArguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $suiteScript, "-Profile", $Profile, "-InstallRoot", $installRootPath, "-ToolsRoot", $toolsRootPath, "-OutputRoot", $outputRootPath)
        if ($InstallFullWDK -or $InstallWdtf) {
            $suiteArguments += "-InstallTools"
        }

        if ($InstallFullWDK) {
            $suiteArguments += "-InstallFullWDK"
        }

        if ($InstallWdtf) {
            $suiteArguments += "-InstallWdtf"
        }

        & powershell.exe @suiteArguments
        if ($LASTEXITCODE -ne 0) {
            throw "Forcys Test Suite run failed with exit code $LASTEXITCODE."
        }
    }

    Write-Section "Done"
    Write-Host "Forcys Test Suite is ready:"
    Write-Host $installRootPath
    Write-Host ""
    Write-Host "Run a short power test later:"
    Write-Host "cd `"$installRootPath`""
    Write-Host ".\Invoke-Forcys.ps1 -Profile Triage -Elevate"
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
