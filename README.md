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
