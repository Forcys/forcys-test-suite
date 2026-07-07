# Tool References

This file tracks external tools used by the Forcys Test Suite.

## PwrTest

`pwrtest.exe` is part of the Windows Driver Kit and can exercise sleep, hibernation, and Modern Standby scenarios from an unattended script.

The test suite bootstraps PwrTest from the NuGet package below instead of requiring a manual WDK install:

- Package: `Microsoft.Windows.WDK.x64`
- Source: `https://api.nuget.org/v3/index.json`
- Staged path: `C:\ProgramData\Forcys\TestSuite\PwrTest\pwrtest.exe`

The staged binary is checked with `Get-AuthenticodeSignature` before test execution.

## NuGet.exe

NuGet is used only as a bootstrap tool for downloading the WDK package.

- Download URL: `https://dist.nuget.org/win-x86-commandline/latest/nuget.exe`
- Staged path: `C:\ProgramData\Forcys\TestSuite\NuGet\nuget.exe`
