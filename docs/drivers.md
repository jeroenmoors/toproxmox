# VirtIO drivers and guest tools

ToProxmox can open the upstream VirtIO Guest Tools installer from its **Install drivers** tab. The complete installer is carried inside the ToProxmox CMD package;
the VM does not need a network connection to download it.

The bundle includes VirtIO drivers and guest agents, including QEMU Guest Agent
and SPICE components. Its interactive wizard handles component selection and
license acceptance. ToProxmox passes `/install /norestart /log` and waits for the
wizard to finish. Opening ToProxmox alone never installs drivers.

The current integration targets x86/x64 Windows 10/11 and Windows Server 2016 or
newer, with Desktop Experience. Actual component availability depends on the
upstream installer and Windows version. Older Windows versions and ARM64 are
rejected by this integration; use a separately validated driver version and
migration procedure for those guests.

## Build with drivers

```powershell
.\build.ps1 package
```

The first build downloads the version pinned in `src/Drivers/virtio-win.json`
from the upstream HTTPS archive and validates its SHA-256. The verified installer
is cached under `.cache/virtio-win/<version>/`. Subsequent builds reuse that copy
and verify its hash again. Neither the cache nor `dist/` belongs in Git.
The output is still a single `dist/ToProxmox.cmd`, approximately 41 MiB with the
currently pinned installer. Base64 encoding increases its size; it also needs more
memory and time to start than a package without drivers.

For an offline build, provide a previously downloaded copy of that exact installer:

```powershell
.\build.ps1 package -DriverInstallerPath C:\Downloads\virtio-win-guest-tools.exe
```

The same manifest hash check applies. This option does not accept arbitrary driver
versions. For a smaller package without the installer:

```powershell
.\build.ps1 package -SkipDrivers
```

The driver button is disabled when the installer is absent. Source checkouts use
the verified build cache, so run `package` before launching `src/ToProxmox.ps1` to
make driver setup available during development.

## Install on a VM

1. Export the original network settings and keep a copy outside the VM.
2. Open the VM console and select **Install drivers**.
3. Click **Install VirtIO drivers...**, confirm, and complete the upstream wizard.
4. Restart Windows if setup requests it. ToProxmox reports the reboot requirement
   and blocks network restore, boot preparation writes, and another installation
   for the current session.
5. Before migration, use [Boot preparation](boot-preparation.md) to check and prepare
   the selected storage driver, then shut down for migration.
6. Verify the devices in Device Manager. After migration, select the new network
   adapter and perform a fresh dry run before restoring its settings.

## Registering the storage device on VMware

The upstream installer only creates the `vioscsi`/`viostor` kernel service when a
matching VirtIO controller is present. On VMware that controller is absent, so the
installer stages the driver package into the DriverStore without registering the
service. [Boot preparation](boot-preparation.md) then reports that the driver
service is missing and refuses to fabricate one.

Use **Register storage device** to resolve this. It reproduces the **Add legacy
hardware** (`hdwwiz`) flow through the Windows SetupAPI: it creates a
root-enumerated device for the staged package's hardware ID
(`PCI\VEN_1AF4&DEV_xxxx`) and force-installs the driver, which creates the kernel
service. No external tools such as `devcon` are required.

1. Install the VirtIO drivers first, so the package is staged.
2. Open **Register storage device** and select **VirtIO SCSI** (`vioscsi`) or
   **VirtIO Block** (`viostor`) to match the intended Proxmox boot controller.
3. Click **Check** to inspect the staged package and report whether the service
   already exists, then **Register** to create the device and service.
4. Continue with [Boot preparation](boot-preparation.md).

The step is idempotent: if the service already exists with a valid registered
driver binary, no new device is created. If a service exists but its registered
binary is missing or unexpected, ToProxmox blocks and asks you to repair or remove
it manually rather than creating a duplicate device.

Run it from the command line inside the VM in an elevated session:

```powershell
.\src\Drivers\Register-VirtioStorage.ps1 -Mode Check -Service vioscsi
.\src\Drivers\Register-VirtioStorage.ps1 -Mode Register -Service vioscsi -WhatIf
.\src\Drivers\Register-VirtioStorage.ps1 -Mode Register -Service vioscsi
```

Use `-Service viostor` only for a VirtIO Block boot disk. `-WhatIf` makes no
changes. These scripts are included in both regular and `-SkipDrivers` packages.

Driver installation shares the operation lock with network export and restore.
Its transcript, structured result, and `virtio-setup.log` are kept under
`C:\ProgramData\NetworkMigration\Logs`, outside the temporary package directory.
Cancelled or failed setup can leave some components changed; review the logs
before retrying. Reboot status is kept only for the current ToProxmox session;
reopening the tool without restarting Windows does not satisfy a required reboot.

Installing the bundle before migration does not by itself guarantee that a
Windows boot disk can be switched to VirtIO. The appropriate storage driver must
be loaded and usable for the selected controller. Use a compatible controller to
boot the migrated guest when necessary, attach a temporary VirtIO device, verify
the driver, and only then change the boot disk controller. ToProxmox does not
change Proxmox hardware settings. QEMU Guest Agent must also be enabled for the
VM in Proxmox if you want to use its host integration.

## Updating the pinned bundle

Update the version, versioned archive URL and SHA-256 in
`src/Drivers/virtio-win.json` together, after obtaining and verifying a new upstream
installer. Do not use a moving `stable-virtio` or `latest-virtio` URL in the manifest.
Run `build.ps1 test`, build the package, and test installation on representative
Windows VMs. Tests use fixture bytes and process stubs; they never install drivers.
See [third-party components](THIRD-PARTY.md) for upstream source and notices.

References:

- [VirtIO driver installation](https://github.com/virtio-win/kvm-guest-drivers-windows/wiki/Driver-installation)
- [Upstream installer](https://github.com/virtio-win/virtio-win-guest-tools-installer)
- [Proxmox migration guide](https://pve.proxmox.com/wiki/Migrate_to_Proxmox_VE)
