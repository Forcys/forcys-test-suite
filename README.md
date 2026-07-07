# Forcys Test Suite

Forcys Test Suite is a collection of scripts and references for testing laptops and computers.

The first test is a PowerShell-based power stability run that bootstraps `pwrtest.exe` from the Windows Driver Kit NuGet package, then exercises sleep, Modern Standby, and hibernation cycles while collecting useful diagnostics.

## Download Or Update

From an elevated PowerShell session, run:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
Invoke-WebRequest https://raw.githubusercontent.com/Forcys/forcys-test-suite/main/install.ps1 -OutFile $env:TEMP\install-forcys-test-suite.ps1
& $env:TEMP\install-forcys-test-suite.ps1 -InstallRoot C:\forcys-test-suite
```

To download/update the suite and immediately bootstrap PwrTest:

```powershell
& $env:TEMP\install-forcys-test-suite.ps1 -InstallRoot C:\forcys-test-suite -SetupPwrTest
```

The installer does not require Git. It updates the repository files while preserving local `tools` and `PwrTest-Logs` folders.

## Power Stability Test

Script:

```powershell
.\scripts\Invoke-ForcysPwrTest.ps1
```

Recommended first run from an elevated PowerShell session:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\scripts\Invoke-ForcysPwrTest.ps1 -SetupOnly
```

If PwrTest exits with code `1285`, install the full Windows Driver Kit and set up again:

```powershell
.\scripts\Invoke-ForcysPwrTest.ps1 -SetupOnly -InstallFullWDK
```

By default the script auto-selects a winget WDK package based on the Windows build. To install a specific WDK package:

```powershell
.\scripts\Invoke-ForcysPwrTest.ps1 -SetupOnly -InstallFullWDK -WdkWingetPackageId Microsoft.WindowsWDK.10.0.28000
```

Auto-selection mapping:

- Windows build `26100` or newer: `Microsoft.WindowsWDK.10.0.26100`
- Windows build `22621`/`22631`: `Microsoft.WindowsWDK.10.0.22621`
- Windows build `22000`: `Microsoft.WindowsWDK.10.0.22000`
- Older Windows 10 builds: `Microsoft.WindowsWDK.10.0.19041`

Available winget WDK package IDs:

- `Microsoft.WindowsWDK.10.0.26100`: Windows 11 24H2 WDK, recommended default.
- `Microsoft.WindowsWDK.10.0.22621`: Windows 11 22H2/23H2 era WDK.
- `Microsoft.WindowsWDK.10.0.22000`: Windows 11 initial release era WDK.
- `Microsoft.WindowsWDK.10.0.19041`: Windows 10 era WDK.
- `Microsoft.WindowsWDK.10.0.28000`: newer/preview WDK line; use only when you specifically need it.

Then run a short smoke test:

```powershell
.\scripts\Invoke-ForcysPwrTest.ps1 -SleepCycles 2 -HibernateCycles 1 -AwakeSeconds 60 -SleepSeconds 30
```

Run defaults are intentionally longer:

```powershell
.\scripts\Invoke-ForcysPwrTest.ps1 -SleepCycles 50 -HibernateCycles 25 -AwakeSeconds 120 -SleepSeconds 60
```

By default the script uses:

- Tools and downloaded packages: `C:\ProgramData\Forcys\TestSuite`
- Test output: `C:\ProgramData\Forcys\TestSuite\PwrTest-Logs`
- PwrTest executable: `C:\ProgramData\Forcys\TestSuite\PwrTest\pwrtest.exe`

The script is designed to be idempotent. It reuses existing downloads and installed tools unless you pass `-ForceRedownloadNuGet`, `-ForceRedownloadWDK`, or `-ForceInstallPwrTest`.

## Notes

Run the actual sleep or hibernation test as Administrator. The script can bootstrap its tools, but the power-state tests and several diagnostic exports require elevated privileges.
