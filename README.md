# ToProxmox

A PowerShell tool that simplifies migrating Windows VMs to Proxmox.
It exports and restores IPv4 network settings and can install bundled VirtIO
drivers and guest tools through a Windows Forms interface. Copying or converting virtual disks and creating Proxmox
VMs are not yet part of the tool.

All project content and contributions must be in English. See [AGENTS.md](AGENTS.md).

## Getting started

Requires Windows with Desktop Experience, Windows PowerShell 5.1, and the Windows
modules NetTCPIP, DnsClient, NetAdapter and PnpDevice. The launcher requests
administrator privileges and starts the interface in Windows PowerShell using STA.
Launching from PowerShell 7 automatically switches to Windows PowerShell for the UI.

Run from the repository:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\ToProxmox.ps1
```

## Building a package

Build with Windows PowerShell 5.1 or PowerShell 7. No external modules are required.
The first build downloads and caches the pinned VirtIO Guest Tools installer:

```powershell
.\build.ps1 package
# Optional: .\build.ps1 package -OutputDirectory C:\Build\ToProxmox
# Without drivers: .\build.ps1 package -SkipDrivers
# Offline build: .\build.ps1 package -DriverInstallerPath C:\Downloads\virtio-win-guest-tools.exe
```

This creates **`dist/ToProxmox.ps1`**, the only file users need to download.
Run the downloaded file inside the Windows VM:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ToProxmox.ps1
```

The package embeds the interface, backend, and verified driver installer as Base64 data. After elevation, if
needed, it extracts them into a unique temporary directory, waits for the interface
to close, and removes the temporary files. No downloads are required at startup.
Exports and logs are stored outside the temporary directory. ExecutionPolicy Bypass
applies only to the launched processes; enforced organizational policy still applies.
The file is a PowerShell script, not an `.exe`.

## Installing VirtIO drivers

Open **3. VirtIO drivers**, click **Install VirtIO drivers...**, and complete the
upstream installation wizard. Export your network settings first and use the VM
console. The bundle includes drivers and guest agents; automatic restarts are
suppressed, and the tool reports when Windows needs a restart.

The driver integration targets x86/x64 Windows 10/11 and Server 2016 or newer.
Installing drivers alone does not guarantee booting from a new storage controller.
See the [driver guide](docs/drivers.md) for migration steps, offline builds, version
pinning, and [third-party components](docs/THIRD-PARTY.md).

## Preparing the boot driver before migration

After installing the drivers and completing any requested restart, open **Boot
preparation**. Select **VirtIO SCSI** (`vioscsi`) or **VirtIO Block** (`viostor`),
check the current settings, then prepare them before shutting down for migration.
The tool verifies the installed service and driver file, backs up the original
values, and sets storage Boot Start and any existing `StartOverride\0` as needed.
NetKVM retains its normal network-driver startup settings.

See [boot preparation](docs/boot-preparation.md) for CLI dry runs, backups,
limitations, and the compatible-controller fallback. A successful configuration
check is not a successful boot test.

## Development

```text
AGENTS.md                    Project language instructions
src/ToProxmox.ps1             Main launcher and package template
src/Network/                 Network backend and Windows Forms interface
src/Drivers/                 Driver installation, checks and pinned version
scripts/Package.ps1           Builds the standalone script
build.ps1                    Package and test commands
tests/                       Build and driver checks without external test modules
docs/                        Network migration and driver guides
dist/                        Generated distribution (excluded from Git)
.cache/                      Downloaded driver cache (excluded from Git)
```

Edit the application code under `src`.

```powershell
.\build.ps1 test
```

The tests check PowerShell syntax, exact embedding of source file bytes, paths
containing spaces, reproducible builds, driver checksums, caching, and installer
exit handling, and storage boot preparation with simulated registry state. They use local fixtures without downloads and do not launch the
interface, install drivers, or change network settings. GitHub Actions runs these checks with Windows PowerShell
5.1 and PowerShell 7 and saves the package as a build artifact.

## Migrating network settings

1. Export the network settings before migration; keep a copy of the JSON file outside the VM.
2. After migration, open ToProxmox through the Proxmox console and use its driver tab to install the target NIC driver if needed.
3. Open the original export, explicitly select the source and target adapters, and perform a dry run.
4. Confirm the restore and verify network connectivity and applications, including after a reboot.

The current backend supports ordinary IPv4 adapters. Additional static routes and
manual IPv6 settings block restoration. NIC teaming and VLAN driver settings are
among the settings that are not migrated. Before restoring, the tool backs up the
target configuration alongside the export, but it does not provide a complete
automatic rollback. Logs are stored under `C:\ProgramData\NetworkMigration\Logs`.
See the [network migration guide](docs/network-migration.txt) for full instructions
and limitations.

Test the interface and network operations on a Windows test VM before using the
tool for production migrations.
