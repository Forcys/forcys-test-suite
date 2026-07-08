# Tool References

This file tracks external tools used by the Forcys Test Suite.

## Built-In Windows Tools

The default suite profile prefers tools already available on Windows 11:

- `powercfg.exe`: power states, requests, wake timers, SleepStudy, system sleep diagnostics, energy report, battery report.
- `wevtutil.exe` and `Get-WinEvent`: event log export and interesting event timelines.
- `msinfo32.exe`, `systeminfo`, `Get-ComputerInfo`, CIM cmdlets, and `driverquery.exe`: hardware, firmware, driver, and OS baseline.
- `Get-Disk`, `Get-PhysicalDisk`, `Get-StorageReliabilityCounter`, `Get-Volume`, `Get-Partition`, and `chkdsk /scan`: built-in storage health and online filesystem scan.
- `Compress-Archive`: final evidence bundle packaging.

## Windows Debugging Tools

`cdb.exe` is used when available to run automated `!analyze -v` dump analysis.

- Typical path: `C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\cdb.exe`
- Symbol cache: `C:\ProgramData\Forcys\TestSuite\Symbols`
- Network symbols can be disabled with the collector's offline symbol option.

## PwrTest

`pwrtest.exe` is part of the Windows Driver Kit and can exercise sleep, hibernation, and Modern Standby scenarios from an unattended script.

The test suite can use PwrTest from a full WDK install, or bootstrap PwrTest from the NuGet package below when a full WDK is not available:

- Package: `Microsoft.Windows.WDK.x64`
- Source: `https://api.nuget.org/v3/index.json`
- Staged path: `C:\ProgramData\Forcys\TestSuite\PwrTest\pwrtest.exe`

The staged binary is checked with `Get-AuthenticodeSignature` before test execution.

Modern Standby `/cs` can require the WDTF virtual power button driver from the full Windows Driver Kit. The suite detects that capability and skips `/cs` when it is absent.

## NuGet.exe

NuGet is used only as a bootstrap tool for downloading the WDK package.

- Download URL: `https://dist.nuget.org/win-x86-commandline/latest/nuget.exe`
- Staged path: `C:\ProgramData\Forcys\TestSuite\NuGet\nuget.exe`
