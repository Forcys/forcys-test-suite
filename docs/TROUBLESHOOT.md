# Troubleshooting

## WDTF virtual power button is missing

`-InstallFullWDK -InstallWdtf` can install the WDK and WDTF runtime without creating the virtual `ROOT\BUTTON` device. PwrTest Modern Standby (`/cs`) needs that device.

Run these commands from an elevated 64-bit PowerShell session.

### 1. Check the device

```powershell
Get-PnpDevice -InstanceId "ROOT\BUTTON\*" -ErrorAction SilentlyContinue |
    Format-Table Status, Class, FriendlyName, InstanceId -Auto
```

Expected result: a device with status `OK`, usually named `Power Button`.

Also check for any WDTF-related device:

```powershell
Get-PnpDevice -ErrorAction SilentlyContinue |
    Where-Object { "$($_.FriendlyName) $($_.InstanceId)" -match "WDTF|Virtual.*Power.*Button|Power.*Button" } |
    Format-Table Status, Class, FriendlyName, InstanceId -Auto
```

### 2. Check installed WDTF components

```powershell
Get-ItemProperty `
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*", `
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" `
    -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match "WDTF|Windows Driver Test|Windows Driver Testing Framework" } |
    Select-Object DisplayName, DisplayVersion, InstallLocation |
    Format-Table -Auto
```

The registry result proves that a runtime package is installed; it does not prove that `ROOT\BUTTON` was provisioned.

In particular, `OneCoreUap_WDTF_Headers_and_Libs_Kit_Content` is not the WDTF runtime. The runtime requires the WDTF Desktop Kit content and product packages. The Forcys full-stack setup downloads the official WDK bootstrapper when those runtime packages are missing.

### 3. Find WDTF button content

```powershell
$inf = Get-ChildItem `
    "C:\Program Files (x86)\Windows Kits\10\Testing\Runtimes" `
    -Recurse -Filter button.inf `
    -ErrorAction SilentlyContinue |
    Select-Object -First 1

$inf | Select-Object FullName
```

The expected path is similar to:

```text
C:\Program Files (x86)\Windows Kits\10\Testing\Runtimes\WDTF\RunTime\Actions\System\button.inf
```

If no file is found, the WDTF Desktop Kit content is missing. Install the WDTF content from the WDK or use Visual Studio WDK test-computer provisioning.

The installer treats a missing result as a supported diagnostic condition. It should report that the file was not found rather than fail with a `.FullName` property error.

### 4. Install the button driver manually

Run this only after step 3 finds `button.inf`:

```powershell
pnputil.exe /add-driver $inf.FullName /install
```

Check the device again:

```powershell
Get-PnpDevice -InstanceId "ROOT\BUTTON\*" -ErrorAction SilentlyContinue |
    Format-Table Status, Class, FriendlyName, InstanceId -Auto
```

### 5. Create the root device with DevCon

If the driver package installed but the device is still absent, locate the 64-bit DevCon tool:

```powershell
$devcon = Get-ChildItem `
    "C:\Program Files (x86)\Windows Kits\10\Tools" `
    -Recurse -Filter devcon.exe `
    -ErrorAction SilentlyContinue |
    Where-Object { $_.DirectoryName -match "\\x64$" } |
    Sort-Object FullName -Descending |
    Select-Object -First 1

$devcon | Select-Object FullName

if (-not $devcon) {
    Write-Warning "64-bit devcon.exe was not found under the Windows Kits Tools folder. Install the WDK Tools component or use Visual Studio WDK provisioning."
    return
}
```

Create the virtual button device:

```powershell
& $devcon.FullName install $inf.FullName "root\button"
```

Do not type `devcon.exe` by itself. DevCon is not normally added to `PATH`; the command above runs the exact WDK copy found in the previous step.

Verify it:

```powershell
Get-PnpDevice -InstanceId "ROOT\BUTTON\*" -ErrorAction SilentlyContinue |
    Format-Table Status, Class, FriendlyName, InstanceId -Auto
```

Reboot after a successful driver or device installation, then repeat the check.

### 6. Run the suite setup check

```powershell
cd C:\forcys-test-suite
.\scripts\Invoke-ForcysPwrTest.ps1 -SetupOnly -InstallFullWDK -InstallWdtf
```

The expected message is:

```text
WDTF virtual power button is present.
```

### 7. Use official provisioning if the device is still absent

If `button.inf` is missing, DevCon cannot be found, or the device remains absent after reboot, use Visual Studio with the WDK:

1. Install Visual Studio and the matching WDK.
2. Open Visual Studio as Administrator.
3. Select `Driver` > `Test` > `Configure Computers`.
4. Provision the local computer as a test computer.
5. Reboot when prompted.
6. Repeat the `ROOT\BUTTON` check above.

Microsoft documents the virtual power button as part of WDTF test-computer provisioning. Installing the WDK and WDTF MSI packages alone is not equivalent to provisioning a test computer.

### 8. Run a fast Modern Standby test

Once the device is present:

```powershell
cd C:\forcys-test-suite
.\scripts\Invoke-ForcysPwrTest.ps1 `
    -SleepCycles 2 `
    -SkipHibernate `
    -AwakeSeconds 60 `
    -SleepSeconds 30 `
    -SkipBaseline `
    -SkipEnergyReport
```

The output should contain `Starting Modern Standby test`. If the machine does not support S0 Low Power Idle, `/cs` cannot run even when the WDTF button is installed.
