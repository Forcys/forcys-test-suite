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
    [string]$RepositoryZipUrl = "https://github.com/Forcys/forcys-test-suite/archive/refs/heads/main.zip",

    [switch]$SetupPwrTest,
    [switch]$Force
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

function Remove-ExistingRepoFile {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    if ($Force) {
        Remove-Item -LiteralPath $Path -Recurse -Force
        return
    }

    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
    else {
        Remove-Item -LiteralPath $Path -Force
    }
}

$installRootPath = Resolve-DirectoryPath -Path $InstallRoot
$tempRoot = Join-Path $env:TEMP ("forcys-test-suite-install-" + [guid]::NewGuid().ToString())
$zipPath = Join-Path $tempRoot "forcys-test-suite.zip"
$extractRoot = Join-Path $tempRoot "extract"

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
    $preserveNames = @(
        ".git",
        ".agents",
        ".codex",
        "tools",
        "PwrTest-Logs"
    )

    foreach ($sourceItem in Get-ChildItem -LiteralPath $sourceRoot.FullName -Force) {
        if ($preserveNames -contains $sourceItem.Name) {
            continue
        }

        $targetPath = Join-Path $installRootPath $sourceItem.Name
        Remove-ExistingRepoFile -Path $targetPath
        Copy-Item -LiteralPath $sourceItem.FullName -Destination $targetPath -Recurse -Force
        Write-Host "Updated $($sourceItem.Name)"
    }

    if ($SetupPwrTest) {
        Write-Section "Setting up PwrTest"
        $pwrTestScript = Join-Path $installRootPath "scripts\Invoke-ForcysPwrTest.ps1"
        if (-not (Test-Path -LiteralPath $pwrTestScript)) {
            throw "PwrTest script not found after update: $pwrTestScript"
        }

        & powershell.exe -ExecutionPolicy Bypass -File $pwrTestScript -SetupOnly
        if ($LASTEXITCODE -ne 0) {
            throw "PwrTest setup failed with exit code $LASTEXITCODE."
        }
    }

    Write-Section "Done"
    Write-Host "Forcys Test Suite is ready:"
    Write-Host $installRootPath
    Write-Host ""
    Write-Host "Run a short power test from an elevated PowerShell session:"
    Write-Host "cd `"$installRootPath`""
    Write-Host ".\scripts\Invoke-ForcysPwrTest.ps1 -SleepCycles 2 -HibernateCycles 1 -AwakeSeconds 60 -SleepSeconds 30"
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
