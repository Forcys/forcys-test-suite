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

    [ValidateSet("Auto", "Native", "PwrTest")]
    [string]$PowerEngine = "PwrTest",

    [ValidateRange(10, 3600)]
    [int]$EnergyDurationSeconds = 120,

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

    [ValidateNotNullOrEmpty()]
    [string]$WdkWingetPackageId = "Auto",

    [string]$WdkPackageVersion,

    [switch]$InstallFullWDK,
    [switch]$InstallWdtf,
    [string]$WdtfInstallerPath,
    [switch]$SetupOnly,
    [switch]$SkipSleep,
    [switch]$SkipHibernate,
    [switch]$SkipEnergyReport,
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

function Ensure-ParentDirectory {
    param([Parameter(Mandatory)][string]$Path)

    $parent = Split-Path -Path $Path -Parent
    if ($parent) {
        Ensure-Directory -Path $parent
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
        Ensure-ParentDirectory -Path $Path
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

function Find-InstalledPwrTest {
    $kitRoots = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\Tools",
        "$env:ProgramFiles\Windows Kits\10\Tools"
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

    foreach ($kitRoot in $kitRoots) {
        $pwrTest = Find-PwrTest -SearchRoot $kitRoot
        if ($pwrTest) {
            return $pwrTest
        }
    }

    return $null
}

function Get-WindowsKitRoots {
    $roots = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10",
        "$env:ProgramFiles\Windows Kits\10"
    )

    $installedPwrTest = Find-InstalledPwrTest
    if ($installedPwrTest -and $installedPwrTest -match "^(.*\\Windows Kits\\10)\\") {
        $roots += $Matches[1]
    }

    return $roots |
        Where-Object { $_ -and (Test-Path -LiteralPath $_) } |
        Select-Object -Unique
}

function Find-WdtfRuntimeInstaller {
    param([string]$ExplicitPath)

    if ($ExplicitPath) {
        $resolvedPath = Resolve-DirectoryPath -Path $ExplicitPath
        if (-not (Test-Path -LiteralPath $resolvedPath)) {
            throw "The WDTF installer path does not exist: $ExplicitPath"
        }

        return $resolvedPath
    }

    $candidateRoots = foreach ($kitRoot in Get-WindowsKitRoots) {
        Join-PathSafe -Path $kitRoot -ChildPath @("Testing", "Runtimes", "WDTF")
        Join-PathSafe -Path $kitRoot -ChildPath @("Testing", "Runtimes")
        Join-PathSafe -Path $kitRoot -ChildPath @("Redist")
        $kitRoot
    }

    $installers = foreach ($candidateRoot in ($candidateRoots | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $candidateRoot) {
            Get-ChildItem -LiteralPath $candidateRoot -Recurse -File -Filter "*.msi" -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -match "WDTF|Windows.*Driver.*Testing|Desktop.*Kit" }
        }
    }

    if (-not $installers) {
        return $null
    }

    $architecturePattern = if ([Environment]::Is64BitOperatingSystem) { "x64|amd64" } else { "x86" }
    $preferred = $installers |
        Sort-Object @{
            Expression = {
                $score = 0
                if ($_.Name -match "WDTF") { $score += 100 }
                if ($_.Name -match "Desktop") { $score += 50 }
                if ($_.Name -match $architecturePattern) { $score += 25 }
                $score
            }
            Descending = $true
        }, FullName |
        Select-Object -First 1

    return $preferred.FullName
}

function Test-WdtfRuntimeInstalled {
    $uninstallRoots = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    foreach ($uninstallRoot in $uninstallRoots) {
        $match = Get-ItemProperty -Path $uninstallRoot -ErrorAction SilentlyContinue |
            Where-Object {
                $_.DisplayName -match "WDTF|Windows Driver Test|Windows Driver Testing Framework"
            } |
            Select-Object -First 1

        if ($match) {
            return $true
        }
    }

    return $false
}

function Test-WdtfVirtualPowerButtonInstalled {
    $wdtfPowerPattern = "WDTF.*(Power|Button)|Virtual.*Power.*Button|Power.*Button.*WDTF"

    try {
        $signedDriver = Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
            Where-Object {
                $_.DeviceName -match $wdtfPowerPattern -or
                (($_.DriverProviderName -match "WDTF|Windows Driver Test") -and ($_.DeviceName -match "Power|Button"))
            } |
            Select-Object -First 1

        if ($signedDriver) {
            return $true
        }
    }
    catch {
    }

    $getPnpDevice = Get-Command Get-PnpDevice -ErrorAction SilentlyContinue
    if ($getPnpDevice) {
        try {
            $pnpDevice = Get-PnpDevice -ErrorAction SilentlyContinue |
                Where-Object { "$($_.FriendlyName) $($_.InstanceId)" -match $wdtfPowerPattern } |
                Select-Object -First 1

            if ($pnpDevice) {
                return $true
            }
        }
        catch {
        }
    }

    return $false
}

function Ensure-WdtfRuntime {
    param([string]$InstallerPath)

    Write-Section "Checking WDTF runtime"

    if (Test-WdtfRuntimeInstalled) {
        Write-Host "WDTF runtime already appears to be installed."
    }
    else {
        $installer = Find-WdtfRuntimeInstaller -ExplicitPath $InstallerPath
        if (-not $installer) {
            throw "WDTF runtime installer was not found under the Windows Kits folder. Install the full Windows Driver Kit, then rerun with -InstallWdtf. You can also pass -WdtfInstallerPath if you know the MSI path."
        }

        Write-Host "Installing WDTF runtime:"
        Write-Host $installer
        $exitCode = Invoke-External -FilePath "msiexec.exe" -Arguments @("/i", $installer, "/qn", "/norestart") -AllowedExitCodes @(0, 3010, 1641)

        if ($exitCode -in @(3010, 1641)) {
            Write-Warning "WDTF install requested a reboot. Reboot before running Modern Standby /cs tests."
        }
    }

    if (Test-WdtfVirtualPowerButtonInstalled) {
        Write-Host "WDTF virtual power button is present."
    }
    else {
        Write-Warning "WDTF runtime was handled, but the virtual power button is not visible yet. A reboot or WDK/WDTF repair may be required before PwrTest /cs can run."
    }
}

function Test-StagedPwrTestAvailable {
    param([Parameter(Mandatory)][string]$PwrTestExe)

    return (Test-Path -LiteralPath $PwrTestExe)
}

function Resolve-PowerEngine {
    param(
        [Parameter(Mandatory)][string]$RequestedEngine,
        [Parameter(Mandatory)][string]$PwrTestExe
    )

    if ($RequestedEngine -ne "Auto") {
        return $RequestedEngine
    }

    if ((Find-InstalledPwrTest) -or (Test-StagedPwrTestAvailable -PwrTestExe $PwrTestExe)) {
        return "PwrTest"
    }

    return "Native"
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
    $sourceDirectory = Split-Path -Path $SourcePwrTest -Parent
    $targetDirectory = Split-Path -Path $TargetPwrTest -Parent
    Ensure-Directory -Path $targetDirectory

    $sourceFiles = Get-ChildItem -LiteralPath $sourceDirectory -File
    $needsCopy = [bool]$Force

    if (-not $needsCopy) {
        foreach ($sourceFile in $sourceFiles) {
            $targetFile = Join-Path $targetDirectory $sourceFile.Name

            if (-not (Test-Path -LiteralPath $targetFile)) {
                $needsCopy = $true
                break
            }

            if ($sourceFile.Length -ne (Get-Item -LiteralPath $targetFile).Length) {
                $needsCopy = $true
                break
            }
        }
    }

    if (-not $needsCopy) {
        Write-Host "PwrTest tool directory is already staged: $targetDirectory"
        return
    }

    Write-Host "Staging PwrTest tool directory:"
    Write-Host $targetDirectory

    foreach ($sourceFile in $sourceFiles) {
        Copy-Item -LiteralPath $sourceFile.FullName -Destination (Join-Path $targetDirectory $sourceFile.Name) -Force
    }

    if (-not (Test-Path -LiteralPath $TargetPwrTest)) {
        throw "Staging PwrTest failed. Target executable was not created: $TargetPwrTest"
    }

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

function Test-FullWindowsDriverKitInstalled {
    return [bool](Find-InstalledPwrTest)
}

function Write-PwrTestRuntimePreflight {
    $installedPwrTest = Find-InstalledPwrTest
    if ($installedPwrTest) {
        Write-Host "Full Windows Driver Kit PwrTest detected:"
        Write-Host $installedPwrTest
        if (Test-WdtfVirtualPowerButtonInstalled) {
            Write-Host "WDTF virtual power button detected for PwrTest Modern Standby /cs."
        }
        else {
            Write-Warning "WDTF virtual power button was not detected. Modern Standby /cs requires WDTF; run setup with -InstallWdtf if you need S0 testing."
        }
        return
    }

    Write-Warning "Full Windows Driver Kit installation was not detected."
    Write-Warning "The NuGet WDK package can provide pwrtest.exe, but PwrTest sleep scenarios may still require full WDK/WDTF runtime components."
    Write-Warning "If PwrTest exits with code 1285, install the full Windows Driver Kit on the test machine and rerun this script."
}

function Get-WindowsBuildNumber {
    try {
        return [int](Get-ItemPropertyValue -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Name "CurrentBuildNumber")
    }
    catch {
        return [Environment]::OSVersion.Version.Build
    }
}

function Resolve-WdkWingetPackageId {
    param([Parameter(Mandatory)][string]$PackageId)

    if ($PackageId -ne "Auto") {
        return $PackageId
    }

    $build = Get-WindowsBuildNumber

    if ($build -ge 26100) {
        return "Microsoft.WindowsWDK.10.0.26100"
    }

    if ($build -ge 22621) {
        return "Microsoft.WindowsWDK.10.0.22621"
    }

    if ($build -ge 22000) {
        return "Microsoft.WindowsWDK.10.0.22000"
    }

    return "Microsoft.WindowsWDK.10.0.19041"
}

function Ensure-FullWindowsDriverKit {
    param([Parameter(Mandatory)][string]$PackageId)

    Write-Section "Checking full Windows Driver Kit"
    $resolvedPackageId = Resolve-WdkWingetPackageId -PackageId $PackageId

    $installedPwrTest = Find-InstalledPwrTest
    if ($installedPwrTest) {
        Write-Host "Full Windows Driver Kit already appears to be installed:"
        Write-Host $installedPwrTest
        return
    }

    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw "winget.exe was not found. Install App Installer from Microsoft Store, or install the Windows Driver Kit manually from Microsoft Learn."
    }

    Write-Host "Installing Windows Driver Kit via winget package:"
    Write-Host $resolvedPackageId
    if ($PackageId -eq "Auto") {
        Write-Host "Auto-selected for Windows build $(Get-WindowsBuildNumber)."
    }
    Write-Warning "The full Windows Driver Kit is large and may take several minutes to install."

    $arguments = @(
        "install",
        "--id", $resolvedPackageId,
        "--source", "winget",
        "--exact",
        "--accept-package-agreements",
        "--accept-source-agreements"
    )

    Invoke-External -FilePath $winget.Source -Arguments $arguments | Out-Null

    $installedPwrTest = Find-InstalledPwrTest
    if (-not $installedPwrTest) {
        throw "Windows Driver Kit installation completed, but pwrtest.exe was not found under Windows Kits. A reboot or manual WDK repair may be required."
    }

    Write-Host "Full Windows Driver Kit PwrTest is ready:"
    Write-Host $installedPwrTest
}

function New-TestRoot {
    param([Parameter(Mandatory)][string]$BaseRoot)

    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $root = Join-Path -Path (Resolve-DirectoryPath -Path $BaseRoot) -ChildPath "Forcys-PwrTest-$stamp"

    foreach ($folder in @(
        $root,
        (Join-PathSafe -Path $root -ChildPath @("Reports")),
        (Join-PathSafe -Path $root -ChildPath @("EventLogs")),
        (Join-PathSafe -Path $root -ChildPath @("PwrTest")),
        (Join-PathSafe -Path $root -ChildPath @("Dumps"))
    )) {
        Ensure-Directory -Path $folder
    }

    return $root
}

function Export-Baseline {
    param(
        [Parameter(Mandatory)][string]$Root,
        [int]$EnergyDuration,
        [switch]$NoEnergyReport
    )

    Write-Section "Collecting baseline"
    $reportsRoot = Join-PathSafe -Path $Root -ChildPath @("Reports")

    Save-CommandOutput -Command { powercfg /a } -Path (Join-PathSafe -Path $reportsRoot -ChildPath @("powercfg-a.txt")) -Description "powercfg /a"
    Save-CommandOutput -Command { powercfg /requests } -Path (Join-PathSafe -Path $reportsRoot -ChildPath @("powercfg-requests-before.txt")) -Description "powercfg /requests"
    Save-CommandOutput -Command { Get-ComputerInfo } -Path (Join-PathSafe -Path $reportsRoot -ChildPath @("computerinfo.txt")) -Description "Get-ComputerInfo"
    Save-CommandOutput -Command { Get-CimInstance Win32_BIOS | Format-List * } -Path (Join-PathSafe -Path $reportsRoot -ChildPath @("bios.txt")) -Description "BIOS inventory"
    Save-CommandOutput -Command { Get-CimInstance Win32_ComputerSystem | Format-List * } -Path (Join-PathSafe -Path $reportsRoot -ChildPath @("computersystem.txt")) -Description "computer system inventory"
    Save-CommandOutput -Command { Get-CimInstance Win32_Processor | Format-List * } -Path (Join-PathSafe -Path $reportsRoot -ChildPath @("processor.txt")) -Description "processor inventory"
    Save-CommandOutput -Command { Get-CimInstance Win32_PhysicalMemory | Format-List * } -Path (Join-PathSafe -Path $reportsRoot -ChildPath @("memory.txt")) -Description "memory inventory"
    Save-CommandOutput -Command { Get-CimInstance Win32_DiskDrive | Format-List * } -Path (Join-PathSafe -Path $reportsRoot -ChildPath @("diskdrives.txt")) -Description "disk inventory"
    Save-CommandOutput -Command { Get-PnpDevice | Sort-Object Class, FriendlyName } -Path (Join-PathSafe -Path $reportsRoot -ChildPath @("pnpdevices-before.txt")) -Description "PnP inventory"
    Save-CommandOutput -Command { driverquery /v /fo csv } -Path (Join-PathSafe -Path $reportsRoot -ChildPath @("driverquery.csv")) -Description "driverquery"

    Invoke-OptionalExternal -FilePath "powercfg.exe" -Arguments @("/batteryreport", "/output", (Join-PathSafe -Path $reportsRoot -ChildPath @("batteryreport.html"))) -Description "battery report"
    if (-not $NoEnergyReport) {
        Write-Host "Collecting powercfg /energy report before test. This takes about $EnergyDuration seconds."
        Invoke-OptionalExternal -FilePath "powercfg.exe" -Arguments @("/energy", "/duration", $EnergyDuration.ToString(), "/output", (Join-PathSafe -Path $reportsRoot -ChildPath @("energy-before.html"))) -Description "energy report before"
    }
    Invoke-OptionalExternal -FilePath "powercfg.exe" -Arguments @("/sleepstudy", "/output", (Join-PathSafe -Path $reportsRoot -ChildPath @("sleepstudy-before.html"))) -Description "sleep study before"
    Invoke-OptionalExternal -FilePath "powercfg.exe" -Arguments @("/systemsleepdiagnostics", "/output", (Join-PathSafe -Path $reportsRoot -ChildPath @("systemsleepdiagnostics-before.html"))) -Description "system sleep diagnostics before"
    Invoke-OptionalExternal -FilePath "msinfo32.exe" -Arguments @("/nfo", (Join-PathSafe -Path $reportsRoot -ChildPath @("msinfo32.nfo"))) -Description "msinfo32 export"
}

function Export-EventLogs {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Stage
    )

    Write-Section "Exporting event logs: $Stage"
    $eventLogsRoot = Join-PathSafe -Path $Root -ChildPath @("EventLogs")

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
        Invoke-OptionalExternal -FilePath "wevtutil.exe" -Arguments @("epl", $log, (Join-PathSafe -Path $eventLogsRoot -ChildPath @("$Stage-$safeName.evtx"))) -Description "event log export for $log"
    }

    Save-CommandOutput -Command {
        Get-WinEvent -LogName System -MaxEvents 500 |
            Where-Object {
                $_.ProviderName -match "Kernel-Power|WHEA|Display|BugCheck|Power-Troubleshooter|USB|ACPI|Intel|Thunderbolt|stornvme|iaStor|Netwtw"
            } |
            Select-Object TimeCreated, ProviderName, Id, LevelDisplayName, Message |
            Format-List
    } -Path (Join-PathSafe -Path $eventLogsRoot -ChildPath @("$Stage-interesting-system-events.txt")) -Description "interesting system event export"
}

function Copy-Dumps {
    param([Parameter(Mandatory)][string]$Root)

    Write-Section "Copying crash dumps"
    $dumpsRoot = Join-PathSafe -Path $Root -ChildPath @("Dumps")

    if (Test-Path -LiteralPath "C:\Windows\Minidump") {
        Copy-Item -Path "C:\Windows\Minidump\*.dmp" -Destination $dumpsRoot -ErrorAction SilentlyContinue
    }

    if (Test-Path -LiteralPath "C:\Windows\MEMORY.DMP") {
        Copy-Item -LiteralPath "C:\Windows\MEMORY.DMP" -Destination $dumpsRoot -ErrorAction SilentlyContinue
    }
}

function Get-AvailablePowerStateText {
    param([Parameter(Mandatory)][string]$PowerCfgOutput)

    $sectionMatch = [regex]::Match(
        $PowerCfgOutput,
        "(?is)(?:The following sleep states are available on this system:|De volgende slaapstanden zijn beschikbaar op dit systeem:)(.*?)(?:The following sleep states are not available on this system:|De volgende slaapstanden zijn niet beschikbaar op dit systeem:|$)"
    )

    if ($sectionMatch.Success) {
        return $sectionMatch.Groups[1].Value
    }

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($PowerCfgOutput -split "\r?\n")) {
        if ($line -match "not available|niet beschikbaar") {
            break
        }

        $lines.Add($line)
    }

    return ($lines -join [Environment]::NewLine)
}

function Get-PowerStateInfo {
    param([Parameter(Mandatory)][string]$Root)

    Write-Section "Detecting power states"
    $states = powercfg /a | Out-String
    $states | Out-File -LiteralPath (Join-PathSafe -Path $Root -ChildPath @("Reports", "power-states.txt")) -Encoding UTF8
    Write-Host $states

    $availableStates = Get-AvailablePowerStateText -PowerCfgOutput $states

    return [pscustomobject]@{
        HasS3 = $availableStates -match "\bS3\b"
        HasS4 = $availableStates -match "\bS4\b|Hibernate|Sluimerstand"
        HasS0 = $availableStates -match "S0 Low Power Idle|Modern Standby|Moderne stand-by|Stand-by \(S0|Connected Standby"
        Raw = $states
        Available = $availableStates
    }
}

function Invoke-PwrTestScenario {
    param(
        [Parameter(Mandatory)][string]$PwrTestExe,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$Name
    )

    $pwrTestDirectory = Split-Path -Path $PwrTestExe -Parent

    try {
        Push-Location -LiteralPath $pwrTestDirectory
        try {
            Invoke-External -FilePath $PwrTestExe -Arguments $Arguments | Out-Null
        }
        finally {
            Pop-Location
        }

        return $true
    }
    catch {
        Write-Warning "$Name did not complete successfully: $($_.Exception.Message)"
        if ($_.Exception.Message -match "exit code 1285") {
            Write-Warning "Exit code 1285 usually means PwrTest failed to load a delayed runtime dependency. The script now runs PwrTest from its staged tool directory; if this still occurs, install the full Windows Driver Kit/WDTF runtime on the test machine."
        }
        Write-Warning "Continuing so after-test reports and other supported scenarios can still run."
        return $false
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
        $pwrTestLogRoot = Join-PathSafe -Path $Root -ChildPath @("PwrTest")

        if ($stateInfo.HasS3) {
            Write-Section "Starting S3 sleep test"
            Invoke-PwrTestScenario -PwrTestExe $PwrTestExe -Arguments @("/sleep", "/c:$SleepCycleCount", "/s:3", "/d:$AwakeDurationSeconds", "/p:$SleepDurationSeconds", "/unattend", "/lf:$pwrTestLogRoot", "/ln:sleep-s3") -Name "S3 sleep test" | Out-Null
        }
        elseif ($stateInfo.HasS0) {
            Write-Section "Starting Modern Standby test"
            if (Test-WdtfVirtualPowerButtonInstalled) {
                Invoke-PwrTestScenario -PwrTestExe $PwrTestExe -Arguments @("/cs", "/c:$SleepCycleCount", "/d:$AwakeDurationSeconds", "/p:$SleepDurationSeconds", "/lf:$pwrTestLogRoot", "/ln:connected-standby") -Name "Modern Standby test" | Out-Null
            }
            else {
                Write-Warning "Modern Standby /cs requires the WDTF virtual power button driver, but it was not detected."
                Write-Warning "Run setup as Administrator with: .\scripts\Invoke-ForcysPwrTest.ps1 -SetupOnly -InstallFullWDK -InstallWdtf"
                Write-Warning "Sleep test skipped so hibernate and after-test reports can still run."
            }
        }
        else {
            Write-Warning "No clear S3 or Modern Standby support detected. Sleep test skipped."
        }
    }

    if (-not $NoHibernate -and $HibernateCycleCount -gt 0) {
        $pwrTestLogRoot = Join-PathSafe -Path $Root -ChildPath @("PwrTest")

        if (-not $stateInfo.HasS4) {
            Write-Host "Hibernate/S4 is not currently reported as available. Trying to enable hibernation."
            Invoke-OptionalExternal -FilePath "powercfg.exe" -Arguments @("/hibernate", "on") -Description "enable hibernation"
            Start-Sleep -Seconds 2
        }

        Write-Section "Starting S4 hibernate test"
        Invoke-PwrTestScenario -PwrTestExe $PwrTestExe -Arguments @("/sleep", "/c:$HibernateCycleCount", "/s:4", "/d:$AwakeDurationSeconds", "/p:$SleepDurationSeconds", "/unattend", "/lf:$pwrTestLogRoot", "/ln:hibernate-s4") -Name "S4 hibernate test" | Out-Null
    }
}

function Register-WakeTask {
    param(
        [Parameter(Mandatory)][datetime]$WakeAt,
        [Parameter(Mandatory)][string]$TaskName
    )

    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -Command `"exit 0`""
    $trigger = New-ScheduledTaskTrigger -Once -At $WakeAt
    $settings = New-ScheduledTaskSettingsSet -WakeToRun -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Compatibility Win8

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
}

function Unregister-WakeTask {
    param([Parameter(Mandatory)][string]$TaskName)

    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    }
    catch {
    }
}

function Invoke-NativePowerTransition {
    param(
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][int]$Cycle,
        [Parameter(Mandatory)][int]$TotalCycles,
        [Parameter(Mandatory)][int]$SleepDurationSeconds,
        [Parameter(Mandatory)][string]$Root
    )

    $wakeAt = (Get-Date).AddSeconds($SleepDurationSeconds)
    $taskName = "ForcysTestSuiteWake-$Mode"
    $logPath = Join-PathSafe -Path $Root -ChildPath @("Reports", "native-power-transitions.csv")

    Ensure-ParentDirectory -Path $logPath
    if (-not (Test-Path -LiteralPath $logPath)) {
        "Timestamp,Mode,Cycle,TotalCycles,WakeAt,Result" | Out-File -LiteralPath $logPath -Encoding UTF8
    }

    Write-Host ("Native {0} cycle {1}/{2}. Wake task scheduled for {3}." -f $Mode, $Cycle, $TotalCycles, $wakeAt.ToString("yyyy-MM-dd HH:mm:ss"))

    Register-WakeTask -WakeAt $wakeAt -TaskName $taskName
    try {
        if ($Mode -eq "Hibernate") {
            rundll32.exe powrprof.dll,SetSuspendState Hibernate
        }
        else {
            rundll32.exe powrprof.dll,SetSuspendState 0,1,0
        }

        Start-Sleep -Seconds 5
        "$(Get-Date -Format o),$Mode,$Cycle,$TotalCycles,$($wakeAt.ToString("o")),Returned" | Out-File -LiteralPath $logPath -Encoding UTF8 -Append
    }
    catch {
        "$(Get-Date -Format o),$Mode,$Cycle,$TotalCycles,$($wakeAt.ToString("o")),Failed: $($_.Exception.Message)" | Out-File -LiteralPath $logPath -Encoding UTF8 -Append
        throw
    }
    finally {
        Unregister-WakeTask -TaskName $taskName
    }
}

function Invoke-NativePowerRuns {
    param(
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
        if ($stateInfo.HasS3 -or $stateInfo.HasS0) {
            Write-Section "Starting native sleep/standby test"
            for ($cycle = 1; $cycle -le $SleepCycleCount; $cycle++) {
                Invoke-NativePowerTransition -Mode "Sleep" -Cycle $cycle -TotalCycles $SleepCycleCount -SleepDurationSeconds $SleepDurationSeconds -Root $Root
                if ($cycle -lt $SleepCycleCount) {
                    Start-Sleep -Seconds $AwakeDurationSeconds
                }
            }
        }
        else {
            Write-Warning "No clear sleep or Modern Standby support detected. Native sleep test skipped."
        }
    }

    if (-not $NoHibernate -and $HibernateCycleCount -gt 0) {
        if (-not $stateInfo.HasS4) {
            Write-Host "Hibernate/S4 is not currently reported as available. Trying to enable hibernation."
            Invoke-OptionalExternal -FilePath "powercfg.exe" -Arguments @("/hibernate", "on") -Description "enable hibernation"
            Start-Sleep -Seconds 2
            $stateInfo = Get-PowerStateInfo -Root $Root
        }

        if ($stateInfo.HasS4) {
            Write-Section "Starting native hibernate test"
            for ($cycle = 1; $cycle -le $HibernateCycleCount; $cycle++) {
                Invoke-NativePowerTransition -Mode "Hibernate" -Cycle $cycle -TotalCycles $HibernateCycleCount -SleepDurationSeconds $SleepDurationSeconds -Root $Root
                if ($cycle -lt $HibernateCycleCount) {
                    Start-Sleep -Seconds $AwakeDurationSeconds
                }
            }
        }
        else {
            Write-Warning "Hibernate/S4 is not available. Native hibernate test skipped."
        }
    }
}

function Export-AfterReports {
    param(
        [Parameter(Mandatory)][string]$Root,
        [int]$EnergyDuration,
        [switch]$NoEnergyReport
    )

    Write-Section "Collecting after-test reports"
    $reportsRoot = Join-PathSafe -Path $Root -ChildPath @("Reports")

    Save-CommandOutput -Command { powercfg /requests } -Path (Join-PathSafe -Path $reportsRoot -ChildPath @("powercfg-requests-after.txt")) -Description "powercfg /requests after"
    Save-CommandOutput -Command { Get-PnpDevice | Sort-Object Class, FriendlyName } -Path (Join-PathSafe -Path $reportsRoot -ChildPath @("pnpdevices-after.txt")) -Description "PnP inventory after"

    if (-not $NoEnergyReport) {
        Write-Host "Collecting powercfg /energy report after test. This takes about $EnergyDuration seconds."
        Invoke-OptionalExternal -FilePath "powercfg.exe" -Arguments @("/energy", "/duration", $EnergyDuration.ToString(), "/output", (Join-PathSafe -Path $reportsRoot -ChildPath @("energy-after.html"))) -Description "energy report after"
    }
    Invoke-OptionalExternal -FilePath "powercfg.exe" -Arguments @("/sleepstudy", "/output", (Join-PathSafe -Path $reportsRoot -ChildPath @("sleepstudy-after.html"))) -Description "sleep study after"
    Invoke-OptionalExternal -FilePath "powercfg.exe" -Arguments @("/systemsleepdiagnostics", "/output", (Join-PathSafe -Path $reportsRoot -ChildPath @("systemsleepdiagnostics-after.html"))) -Description "system sleep diagnostics after"
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

    $readme | Out-File -LiteralPath (Join-PathSafe -Path $Root -ChildPath @("README.txt")) -Encoding UTF8
}

Assert-Administrator
Assert-NativePowerShell

$nuGetExe = Join-Path $ToolsRoot "NuGet\nuget.exe"
$wdkRoot = Join-Path $ToolsRoot "WDK-NuGet"
$pwrTestExe = Join-Path $ToolsRoot "PwrTest\pwrtest.exe"

Ensure-Directory -Path $ToolsRoot
Ensure-Directory -Path $OutputRoot

Write-Section "Forcys PwrTest setup"

if ($InstallFullWDK) {
    Ensure-FullWindowsDriverKit -PackageId $WdkWingetPackageId
}

if ($InstallWdtf) {
    if (-not (Find-InstalledPwrTest)) {
        if ($InstallFullWDK) {
            throw "Windows Driver Kit installation did not expose pwrtest.exe, so WDTF setup cannot continue."
        }

        throw "WDTF setup requires the full Windows Driver Kit. Rerun with -InstallFullWDK -InstallWdtf, or install WDK manually and rerun with -InstallWdtf."
    }

    Ensure-WdtfRuntime -InstallerPath $WdtfInstallerPath
}

$resolvedPowerEngine = Resolve-PowerEngine -RequestedEngine $PowerEngine -PwrTestExe $pwrTestExe
Write-Host "Power engine: $resolvedPowerEngine"

$installedPwrTest = Find-InstalledPwrTest
$foundPwrTest = $null

if ($resolvedPowerEngine -eq "PwrTest") {
    if ($installedPwrTest) {
        Write-Host "Using PwrTest from the installed Windows Driver Kit:"
        Write-Host $installedPwrTest
        $foundPwrTest = $installedPwrTest
    }
    elseif ((Test-StagedPwrTestAvailable -PwrTestExe $pwrTestExe) -and -not $ForceInstallPwrTest) {
        Write-Host "Using already staged PwrTest:"
        Write-Host $pwrTestExe
        $foundPwrTest = $pwrTestExe
    }
    else {
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
    }

    if (-not $foundPwrTest) {
        throw "pwrtest.exe was not found. Install the full WDK with -InstallFullWDK or use -PowerEngine Native."
    }

    if ($foundPwrTest -ne $pwrTestExe) {
        Ensure-PwrTestTool -SourcePwrTest $foundPwrTest -TargetPwrTest $pwrTestExe -Force:$ForceInstallPwrTest
    }
    Test-PwrTestSignature -PwrTestExe $pwrTestExe
    Write-PwrTestRuntimePreflight

    Write-Verbose "Skipping PwrTest help check during setup. PwrTest can return a nonzero code for help output when ETW requirements are not satisfied."
}
else {
    Write-Host "Native power engine selected. No NuGet, WDK, or PwrTest download is required."
}


if ($SetupOnly) {
    Write-Host ""
    Write-Host "SetupOnly selected."
    if ($resolvedPowerEngine -eq "PwrTest") {
        Write-Host "PwrTest is ready:"
        Write-Host $pwrTestExe
    }
    else {
        Write-Host "Native power engine is ready. No external setup was needed."
    }
    return
}

$testRoot = New-TestRoot -BaseRoot $OutputRoot
$transcriptStarted = $false

try {
    Start-Transcript -Path (Join-PathSafe -Path $testRoot -ChildPath @("transcript.txt")) -Force | Out-Null
    $transcriptStarted = $true

    Write-Section "Test output"
    Write-Host $testRoot

    Export-Baseline -Root $testRoot -EnergyDuration $EnergyDurationSeconds -NoEnergyReport:$SkipEnergyReport
    Export-EventLogs -Root $testRoot -Stage "before"

    if ($resolvedPowerEngine -eq "PwrTest") {
        Invoke-PwrTestRuns `
            -PwrTestExe $pwrTestExe `
            -Root $testRoot `
            -SleepCycleCount $SleepCycles `
            -HibernateCycleCount $HibernateCycles `
            -AwakeDurationSeconds $AwakeSeconds `
            -SleepDurationSeconds $SleepSeconds `
            -NoSleep:$SkipSleep `
            -NoHibernate:$SkipHibernate
    }
    else {
        Invoke-NativePowerRuns `
            -Root $testRoot `
            -SleepCycleCount $SleepCycles `
            -HibernateCycleCount $HibernateCycles `
            -AwakeDurationSeconds $AwakeSeconds `
            -SleepDurationSeconds $SleepSeconds `
            -NoSleep:$SkipSleep `
            -NoHibernate:$SkipHibernate
    }

    Export-AfterReports -Root $testRoot -EnergyDuration $EnergyDurationSeconds -NoEnergyReport:$SkipEnergyReport
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
    Write-Host (Join-PathSafe -Path $testRoot -ChildPath @("README.txt"))
}
finally {
    if ($transcriptStarted) {
        Stop-Transcript | Out-Null
    }
}
