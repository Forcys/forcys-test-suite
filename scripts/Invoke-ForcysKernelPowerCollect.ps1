#requires -Version 5.1
<#
.SYNOPSIS
Collects kernel-power crash diagnostics into a timestamped log folder.

.DESCRIPTION
Creates a structured snapshot of the machine for Kernel-Power / unexpected
restart triage:
- baseline hardware and power configuration
- recent event log exports
- a CSV of recent "interesting" System/Application events
- crash dump copies when present
- optional minidump analysis via cdb.exe when Windows Debugging Tools exist
- optional powercfg reports

The output is designed to be easy to archive and parse later.
#>

[CmdletBinding()]
param(
    [ValidateRange(1, 365)]
    [int]$LookbackDays = 7,

    [ValidateRange(10, 3600)]
    [int]$EnergyDurationSeconds = 120,

    [ValidateNotNullOrEmpty()]
    [string]$OutputRoot = (Join-Path $env:ProgramData "Forcys\TestSuite\KernelPower-Logs"),

    [string]$DebuggerPath,

    [ValidateNotNullOrEmpty()]
    [string]$SymbolCache = (Join-Path $env:ProgramData "Forcys\TestSuite\Symbols"),

    [switch]$SkipEnergyReport,
    [switch]$SkipBatteryReport,
    [switch]$SkipDumpCopy,
    [switch]$SkipDumpAnalysis,
    [switch]$SkipStorageScan,
    [switch]$ConfigureMinidumps,
    [switch]$OfflineSymbols
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

function Ensure-ParentDirectory {
    param([Parameter(Mandatory)][string]$Path)

    $parent = Split-Path -Path $Path -Parent
    if ($parent) {
        Ensure-Directory -Path $parent
    }
}

function Save-Text {
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

function Save-External {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Description
    )

    try {
        Ensure-ParentDirectory -Path $Path
        & $FilePath @Arguments | Out-File -LiteralPath $Path -Encoding UTF8
        if ($LASTEXITCODE -ne 0) {
            throw "exit code $LASTEXITCODE"
        }
    }
    catch {
        Write-Warning "$Description failed: $($_.Exception.Message)"
    }
}

function Save-Json {
    param(
        [Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)][string]$Path
    )

    Ensure-ParentDirectory -Path $Path
    $InputObject | ConvertTo-Json -Depth 8 | Out-File -LiteralPath $Path -Encoding UTF8
}

function New-TestRoot {
    param([Parameter(Mandatory)][string]$BaseRoot)

    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $root = Join-Path -Path $BaseRoot -ChildPath "KernelPower-$stamp"

    foreach ($folder in @(
        $root,
        (Join-PathSafe -Path $root -ChildPath @("Reports")),
        (Join-PathSafe -Path $root -ChildPath @("EventLogs")),
        (Join-PathSafe -Path $root -ChildPath @("Dumps"))
    )) {
        Ensure-Directory -Path $folder
    }

    return $root
}

function Set-MiniDumpConfiguration {
    param([Parameter(Mandatory)][string]$ReportsRoot)

    $registryPath = "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl"
    $beforePath = Join-PathSafe -Path $ReportsRoot -ChildPath @("crashcontrol-before.txt")
    $afterPath = Join-PathSafe -Path $ReportsRoot -ChildPath @("crashcontrol-after.txt")

    Save-Text -Command { Get-ItemProperty -LiteralPath $registryPath | Format-List * } -Path $beforePath -Description "CrashControl settings before"

    if (-not (Test-IsAdministrator)) {
        Write-Warning "ConfigureMinidumps was requested, but this PowerShell session is not elevated. Crash dump settings were not changed."
        return
    }

    New-ItemProperty -LiteralPath $registryPath -Name "CrashDumpEnabled" -PropertyType DWord -Value 3 -Force | Out-Null
    New-ItemProperty -LiteralPath $registryPath -Name "LogEvent" -PropertyType DWord -Value 1 -Force | Out-Null
    New-ItemProperty -LiteralPath $registryPath -Name "Overwrite" -PropertyType DWord -Value 1 -Force | Out-Null
    New-ItemProperty -LiteralPath $registryPath -Name "MinidumpDir" -PropertyType ExpandString -Value "%SystemRoot%\Minidump" -Force | Out-Null

    Save-Text -Command { Get-ItemProperty -LiteralPath $registryPath | Format-List * } -Path $afterPath -Description "CrashControl settings after"
}

function Export-EventLogs {
    param(
        [Parameter(Mandatory)][string]$Root
    )

    $eventLogsRoot = Join-PathSafe -Path $Root -ChildPath @("EventLogs")
    $logs = @(
        "System",
        "Application",
        "Setup",
        "Microsoft-Windows-Diagnostics-Performance/Operational",
        "Microsoft-Windows-Power-Troubleshooter/Operational",
        "Microsoft-Windows-Kernel-Boot/Operational",
        "Microsoft-Windows-Kernel-Power/Thermal-Operational"
    )

    foreach ($log in $logs) {
        $safeName = $log -replace "[\\/:]", "_"
        Save-External -FilePath "wevtutil.exe" -Arguments @("epl", $log, (Join-PathSafe -Path $eventLogsRoot -ChildPath @("$safeName.evtx"))) -Path (Join-PathSafe -Path $eventLogsRoot -ChildPath @("$safeName.export.txt")) -Description "event log export for $log"
    }
}

function Get-InterestingEvents {
    param(
        [Parameter(Mandatory)][datetime]$StartTime
    )

    $interestingProviders = @(
        "Microsoft-Windows-Kernel-Power",
        "WHEA-Logger",
        "Display",
        "nvlddmkm",
        "stornvme",
        "iaStorA",
        "iaStorAC",
        "ACPI",
        "Disk",
        "volmgr",
        "Kernel-Boot",
        "Kernel-General",
        "Power-Troubleshooter",
        "USBHUB",
        "USBXHCI",
        "Netwtw"
    )

    $interestingIds = @(
        41, 42, 43, 55, 57, 87, 88, 98, 1001, 1006, 1008, 1010, 1011, 109,
        131, 153, 161, 162, 164, 171, 172, 180, 181, 187, 188, 219, 225,
        4101, 6005, 6006, 6008, 7023, 7026
    )

    $logs = @("System", "Application")
    $rows = New-Object System.Collections.Generic.List[object]

    foreach ($log in $logs) {
        try {
            $events = Get-WinEvent -FilterHashtable @{ LogName = $log; StartTime = $StartTime } -ErrorAction Stop
        }
        catch {
            Write-Warning ("Could not query {0}: {1}" -f $log, $_.Exception.Message)
            continue
        }

        foreach ($event in $events) {
            $provider = $event.ProviderName
            $message = $event.Message

            if (($interestingProviders | Where-Object { $provider -like "*$_*" }) -or ($interestingIds -contains $event.Id) -or ($message -match "Kernel-Power|WHEA|unexpected shutdown|bugcheck|display driver|nvlddmkm|power loss")) {
                $rows.Add([pscustomobject]@{
                    LogName      = $log
                    TimeCreated  = $event.TimeCreated
                    ProviderName = $provider
                    Id           = $event.Id
                    Level        = $event.LevelDisplayName
                    RecordId     = $event.RecordId
                    Message      = $message
                })
            }
        }
    }

    return $rows
}

function Copy-Dumps {
    param([Parameter(Mandatory)][string]$Root)

    $dumpsRoot = Join-PathSafe -Path $Root -ChildPath @("Dumps")

    if (Test-Path -LiteralPath "C:\Windows\Minidump") {
        Copy-Item -Path "C:\Windows\Minidump\*.dmp" -Destination $dumpsRoot -ErrorAction SilentlyContinue
    }

    if (Test-Path -LiteralPath "C:\Windows\MEMORY.DMP") {
        Copy-Item -LiteralPath "C:\Windows\MEMORY.DMP" -Destination $dumpsRoot -ErrorAction SilentlyContinue
    }
}

function Find-Debugger {
    param([string]$RequestedPath)

    if ($RequestedPath) {
        if (Test-Path -LiteralPath $RequestedPath) {
            return $RequestedPath
        }

        Write-Warning "Requested debugger path does not exist: $RequestedPath"
    }

    $command = Get-Command "cdb.exe" -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $candidateRoots = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\Debuggers\x64",
        "$env:ProgramFiles\Windows Kits\10\Debuggers\x64",
        "${env:ProgramFiles(x86)}\Windows Kits\11\Debuggers\x64",
        "$env:ProgramFiles\Windows Kits\11\Debuggers\x64"
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

    foreach ($root in $candidateRoots) {
        $candidate = Join-Path -Path $root -ChildPath "cdb.exe"
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    return $null
}

function Get-SymbolPath {
    param(
        [Parameter(Mandatory)][string]$CachePath,
        [switch]$Offline
    )

    Ensure-Directory -Path $CachePath

    if ($Offline) {
        return "srv*$CachePath"
    }

    return "srv*$CachePath*https://msdl.microsoft.com/download/symbols"
}

function Get-DumpAnalysisSummary {
    param(
        [Parameter(Mandatory)][string]$DumpPath,
        [Parameter(Mandatory)][string]$AnalysisPath
    )

    $text = Get-Content -LiteralPath $AnalysisPath -Raw -ErrorAction SilentlyContinue

    function Find-Value {
        param([Parameter(Mandatory)][string]$Pattern)

        $match = [regex]::Match($text, $Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($match.Success) {
            return $match.Groups[1].Value.Trim()
        }

        return $null
    }

    return [pscustomobject]@{
        DumpFile        = Split-Path -Path $DumpPath -Leaf
        DumpPath        = $DumpPath
        AnalysisPath    = $AnalysisPath
        BugCheckCode    = Find-Value -Pattern "(?m)^BUGCHECK_CODE:\s+(.+)$"
        BugCheckP1      = Find-Value -Pattern "(?m)^BUGCHECK_P1:\s+(.+)$"
        BugCheckP2      = Find-Value -Pattern "(?m)^BUGCHECK_P2:\s+(.+)$"
        BugCheckP3      = Find-Value -Pattern "(?m)^BUGCHECK_P3:\s+(.+)$"
        BugCheckP4      = Find-Value -Pattern "(?m)^BUGCHECK_P4:\s+(.+)$"
        ProbablyCausedBy = Find-Value -Pattern "(?m)^Probably caused by\s+:\s+(.+)$"
        ModuleName      = Find-Value -Pattern "(?m)^MODULE_NAME:\s+(.+)$"
        ImageName       = Find-Value -Pattern "(?m)^IMAGE_NAME:\s+(.+)$"
        ProcessName     = Find-Value -Pattern "(?m)^PROCESS_NAME:\s+(.+)$"
        FailureBucketId = Find-Value -Pattern "(?m)^FAILURE_BUCKET_ID:\s+(.+)$"
        AnalysisError   = Find-Value -Pattern "(?m)^(.*(?:Could not|Unable to|ERROR:).*)$"
    }
}

function Invoke-DumpAnalysis {
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$RequestedDebuggerPath,
        [Parameter(Mandatory)][string]$SymbolCachePath,
        [switch]$UseOfflineSymbols
    )

    $dumpsRoot = Join-PathSafe -Path $Root -ChildPath @("Dumps")
    $analysisRoot = Join-PathSafe -Path $Root -ChildPath @("Reports", "DumpAnalysis")
    Ensure-Directory -Path $analysisRoot

    $dumps = @(Get-ChildItem -LiteralPath $dumpsRoot -Filter "*.dmp" -File -ErrorAction SilentlyContinue)
    if ($dumps.Count -eq 0) {
        "No dump files were found in $dumpsRoot." | Out-File -LiteralPath (Join-PathSafe -Path $analysisRoot -ChildPath @("README.txt")) -Encoding UTF8
        return @()
    }

    $debugger = Find-Debugger -RequestedPath $RequestedDebuggerPath
    if (-not $debugger) {
        @"
Minidumps were collected, but automatic dump analysis was skipped because cdb.exe was not found.

Install Windows Debugging Tools, then rerun with:
.\scripts\Invoke-ForcysKernelPowerCollect.ps1 -DebuggerPath "C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\cdb.exe"

Collected dumps:
$($dumps.FullName -join [Environment]::NewLine)
"@ | Out-File -LiteralPath (Join-PathSafe -Path $analysisRoot -ChildPath @("README.txt")) -Encoding UTF8
        return @()
    }

    $symbolPath = Get-SymbolPath -CachePath $SymbolCachePath -Offline:$UseOfflineSymbols
    $summaries = New-Object System.Collections.Generic.List[object]

    foreach ($dump in $dumps) {
        $analysisPath = Join-PathSafe -Path $analysisRoot -ChildPath @("$($dump.BaseName).analysis.txt")
        $arguments = @(
            "-y", $symbolPath,
            "-z", $dump.FullName,
            "-c", "!analyze -v; lmtn; q"
        )

        try {
            Write-Host "Analyzing dump: $($dump.Name)"
            & $debugger @arguments 2>&1 | Out-File -LiteralPath $analysisPath -Encoding UTF8
            $summaries.Add((Get-DumpAnalysisSummary -DumpPath $dump.FullName -AnalysisPath $analysisPath))
        }
        catch {
            "Dump analysis failed: $($_.Exception.Message)" | Out-File -LiteralPath $analysisPath -Encoding UTF8
            $summaries.Add([pscustomobject]@{
                DumpFile        = $dump.Name
                DumpPath        = $dump.FullName
                AnalysisPath    = $analysisPath
                BugCheckCode    = $null
                BugCheckP1      = $null
                BugCheckP2      = $null
                BugCheckP3      = $null
                BugCheckP4      = $null
                ProbablyCausedBy = $null
                ModuleName      = $null
                ImageName       = $null
                ProcessName     = $null
                FailureBucketId = $null
                AnalysisError   = $_.Exception.Message
            })
        }
    }

    $summaries |
        Export-Csv -LiteralPath (Join-PathSafe -Path $analysisRoot -ChildPath @("dump-analysis-summary.csv")) -NoTypeInformation -Encoding UTF8

    return $summaries
}

function Write-CollectorReadme {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][datetime]$StartTime,
        [Parameter(Mandatory)][int]$LookbackDays,
        [int]$DumpAnalysisCount
    )

    $readme = @"
Forcys Kernel-Power Collector

Collection time:
$(Get-Date -Format "yyyy-MM-dd HH:mm:ss zzz")

Lookback window:
$LookbackDays day(s)

Event start:
$(Get-Date -Date $StartTime -Format "yyyy-MM-dd HH:mm:ss zzz")

Output folder:
$Root

Use this folder for:
- recent event logs in `EventLogs`
- exported reports in `Reports`
- crash dumps in `Dumps`
- dump analysis in `Reports\DumpAnalysis`
- crash dump configuration in `Reports\crashcontrol-before.txt` and `Reports\crashcontrol-after.txt` when configured
- the transcript in `transcript.txt`

Automatic dump analyses:
$DumpAnalysisCount

Good next checks:
1. Compare Kernel-Power 41, WHEA-Logger, Display 4101, and unexpected shutdown events by timestamp.
2. Check whether the machine was on AC power, under load, or resuming from sleep before the crash.
3. If there are WHEA errors, focus on BIOS/UEFI, CPU, RAM, PCIe, storage, and GPU stability.
4. If there are Display 4101 events, focus on the GPU path, driver version, power connectors, and temperatures.
"@

    $readme | Out-File -LiteralPath (Join-PathSafe -Path $Root -ChildPath @("README.txt")) -Encoding UTF8
}

$startTime = (Get-Date).AddDays(-$LookbackDays)
$testRoot = New-TestRoot -BaseRoot $OutputRoot
$transcriptStarted = $false

try {
    Start-Transcript -Path (Join-PathSafe -Path $testRoot -ChildPath @("transcript.txt")) -Force | Out-Null
    $transcriptStarted = $true

    Write-Section "Forcys Kernel-Power collector"
    Write-Host $testRoot

    $reportsRoot = Join-PathSafe -Path $testRoot -ChildPath @("Reports")

    Save-Text -Command { systeminfo } -Path (Join-PathSafe -Path $reportsRoot -ChildPath @("systeminfo.txt")) -Description "systeminfo"
    Save-Text -Command { Get-ComputerInfo } -Path (Join-PathSafe -Path $reportsRoot -ChildPath @("computerinfo.txt")) -Description "Get-ComputerInfo"
    Save-Text -Command { Get-CimInstance Win32_BIOS | Format-List * } -Path (Join-PathSafe -Path $reportsRoot -ChildPath @("bios.txt")) -Description "BIOS inventory"
    Save-Text -Command { Get-CimInstance Win32_BaseBoard | Format-List * } -Path (Join-PathSafe -Path $reportsRoot -ChildPath @("baseboard.txt")) -Description "baseboard inventory"
    Save-Text -Command { Get-CimInstance Win32_ComputerSystem | Format-List * } -Path (Join-PathSafe -Path $reportsRoot -ChildPath @("computersystem.txt")) -Description "computer system inventory"
    Save-Text -Command { Get-CimInstance Win32_Processor | Format-List * } -Path (Join-PathSafe -Path $reportsRoot -ChildPath @("processor.txt")) -Description "processor inventory"
    Save-Text -Command { Get-CimInstance Win32_PhysicalMemory | Format-List * } -Path (Join-PathSafe -Path $reportsRoot -ChildPath @("memory.txt")) -Description "memory inventory"
    Save-Text -Command { Get-CimInstance Win32_DiskDrive | Format-List * } -Path (Join-PathSafe -Path $reportsRoot -ChildPath @("diskdrives.txt")) -Description "disk inventory"
    Save-Text -Command { Get-Disk | Format-List * } -Path (Join-PathSafe -Path $reportsRoot -ChildPath @("get-disk.txt")) -Description "Get-Disk inventory"
    Save-Text -Command { Get-PhysicalDisk | Format-List * } -Path (Join-PathSafe -Path $reportsRoot -ChildPath @("physicaldisk.txt")) -Description "physical disk inventory"
    Save-Text -Command { Get-PhysicalDisk | Get-StorageReliabilityCounter | Format-List * } -Path (Join-PathSafe -Path $reportsRoot -ChildPath @("storage-reliability.txt")) -Description "storage reliability counters"
    Save-Text -Command { Get-Volume | Format-List * } -Path (Join-PathSafe -Path $reportsRoot -ChildPath @("volumes.txt")) -Description "volume inventory"
    Save-Text -Command { Get-Partition | Format-List * } -Path (Join-PathSafe -Path $reportsRoot -ChildPath @("partitions.txt")) -Description "partition inventory"
    Save-Text -Command { Get-CimInstance Win32_VideoController | Format-List * } -Path (Join-PathSafe -Path $reportsRoot -ChildPath @("videocontroller.txt")) -Description "GPU inventory"
    Save-Text -Command { Get-NetAdapter | Format-Table -AutoSize } -Path (Join-PathSafe -Path $reportsRoot -ChildPath @("netadapters.txt")) -Description "network adapter inventory"
    Save-Text -Command { Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl" | Format-List * } -Path (Join-PathSafe -Path $reportsRoot -ChildPath @("crashcontrol.txt")) -Description "CrashControl settings"
    Save-Text -Command { powercfg /a } -Path (Join-PathSafe -Path $reportsRoot -ChildPath @("powercfg-a.txt")) -Description "powercfg /a"
    Save-Text -Command { powercfg /requests } -Path (Join-PathSafe -Path $reportsRoot -ChildPath @("powercfg-requests.txt")) -Description "powercfg /requests"
    Save-Text -Command { powercfg /lastwake } -Path (Join-PathSafe -Path $reportsRoot -ChildPath @("powercfg-lastwake.txt")) -Description "powercfg /lastwake"
    Save-Text -Command { powercfg /devicequery wake_armed } -Path (Join-PathSafe -Path $reportsRoot -ChildPath @("powercfg-wake-armed.txt")) -Description "powercfg /devicequery wake_armed"
    Save-Text -Command { powercfg /waketimers } -Path (Join-PathSafe -Path $reportsRoot -ChildPath @("powercfg-waketimers.txt")) -Description "powercfg /waketimers"
    Save-Text -Command { driverquery /v /fo csv } -Path (Join-PathSafe -Path $reportsRoot -ChildPath @("driverquery.csv")) -Description "driverquery"

    if (-not $SkipStorageScan -and $env:SystemDrive) {
        Save-External -FilePath "chkdsk.exe" -Arguments @($env:SystemDrive, "/scan") -Path (Join-PathSafe -Path $reportsRoot -ChildPath @("chkdsk-system-drive-scan.txt")) -Description "online chkdsk scan"
    }

    if (-not $SkipBatteryReport) {
        Save-External -FilePath "powercfg.exe" -Arguments @("/batteryreport", "/output", (Join-PathSafe -Path $reportsRoot -ChildPath @("batteryreport.html"))) -Path (Join-PathSafe -Path $reportsRoot -ChildPath @("batteryreport.log")) -Description "battery report"
    }

    if (-not $SkipEnergyReport) {
        Write-Host "Collecting powercfg /energy (about $EnergyDurationSeconds seconds)..."
        Save-External -FilePath "powercfg.exe" -Arguments @("/energy", "/duration", $EnergyDurationSeconds.ToString(), "/output", (Join-PathSafe -Path $reportsRoot -ChildPath @("energy.html"))) -Path (Join-PathSafe -Path $reportsRoot -ChildPath @("energy.log")) -Description "energy report"
    }

    Save-External -FilePath "powercfg.exe" -Arguments @("/sleepstudy", "/output", (Join-PathSafe -Path $reportsRoot -ChildPath @("sleepstudy.html"))) -Path (Join-PathSafe -Path $reportsRoot -ChildPath @("sleepstudy.log")) -Description "sleep study"
    Save-External -FilePath "powercfg.exe" -Arguments @("/systemsleepdiagnostics", "/output", (Join-PathSafe -Path $reportsRoot -ChildPath @("systemsleepdiagnostics.html"))) -Path (Join-PathSafe -Path $reportsRoot -ChildPath @("systemsleepdiagnostics.log")) -Description "system sleep diagnostics"
    Save-External -FilePath "msinfo32.exe" -Arguments @("/nfo", (Join-PathSafe -Path $reportsRoot -ChildPath @("msinfo32.nfo"))) -Path (Join-PathSafe -Path $reportsRoot -ChildPath @("msinfo32.log")) -Description "msinfo32 export"

    if ($ConfigureMinidumps) {
        Set-MiniDumpConfiguration -ReportsRoot $reportsRoot
    }

    Export-EventLogs -Root $testRoot

    $events = Get-InterestingEvents -StartTime $startTime
    $events |
        Sort-Object TimeCreated, LogName, ProviderName, Id |
        Export-Csv -LiteralPath (Join-PathSafe -Path $reportsRoot -ChildPath @("interesting-events.csv")) -NoTypeInformation -Encoding UTF8

    if (-not $SkipDumpCopy) {
        Copy-Dumps -Root $testRoot
    }

    $dumpAnalysis = @()
    if (-not $SkipDumpAnalysis) {
        $dumpAnalysis = @(Invoke-DumpAnalysis -Root $testRoot -RequestedDebuggerPath $DebuggerPath -SymbolCachePath $SymbolCache -UseOfflineSymbols:$OfflineSymbols)
    }

    Write-CollectorReadme -Root $testRoot -StartTime $startTime -LookbackDays $LookbackDays -DumpAnalysisCount $dumpAnalysis.Count

    $summary = [pscustomobject]@{
        CollectedAt           = Get-Date
        LookbackDays          = $LookbackDays
        StartTime             = $startTime
        OutputRoot            = $testRoot
        InterestingEventCount = $events.Count
        DumpAnalysisCount     = $dumpAnalysis.Count
        ConfigureMinidumps    = [bool]$ConfigureMinidumps
        SymbolCache           = $SymbolCache
        OfflineSymbols        = [bool]$OfflineSymbols
        Files                 = @(
            "README.txt",
            "transcript.txt",
            "Reports\interesting-events.csv",
            "Reports\DumpAnalysis\dump-analysis-summary.csv",
            "Reports\DumpAnalysis\*.analysis.txt",
            "Reports\powercfg-a.txt",
            "Reports\powercfg-requests.txt",
            "Reports\powercfg-lastwake.txt",
            "Reports\powercfg-wake-armed.txt",
            "Reports\powercfg-waketimers.txt",
            "Reports\get-disk.txt",
            "Reports\physicaldisk.txt",
            "Reports\storage-reliability.txt",
            "Reports\volumes.txt",
            "Reports\partitions.txt",
            "Reports\chkdsk-system-drive-scan.txt",
            "EventLogs\*.evtx",
            "Dumps\*"
        )
    }
    Save-Json -InputObject $summary -Path (Join-PathSafe -Path $reportsRoot -ChildPath @("manifest.json"))

    Write-Section "Done"
    Write-Host "Output:"
    Write-Host $testRoot
    Write-Host ""
    Write-Host "Best file to start with:"
    Write-Host (Join-PathSafe -Path $reportsRoot -ChildPath @("interesting-events.csv"))
    Write-Host ""
    Write-Host "Dump analysis summary:"
    Write-Host (Join-PathSafe -Path $reportsRoot -ChildPath @("DumpAnalysis", "dump-analysis-summary.csv"))
}
finally {
    if ($transcriptStarted) {
        Stop-Transcript | Out-Null
    }
}
