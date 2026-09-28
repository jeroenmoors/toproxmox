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

This creates **`dist/ToProxmox.cmd`**, the only file users need to download.
**Double-click `ToProxmox.cmd` inside the Windows VM**, then accept the
administrator prompt. No PowerShell file-association changes are needed.
You can also start it from a terminal:

```powershell
.\ToProxmox.cmd
```

The package contains a short Windows CMD launcher and the embedded PowerShell tool,
interface, backend, and verified driver installer. The launcher extracts the
PowerShell entry point to a unique temporary directory and runs Windows PowerShell.
The entry point handles elevation and extracts the application files. Both layers
wait for the interface to close before removing their temporary files. No downloads are required at startup.
Exports and logs are stored outside the temporary directory. ExecutionPolicy Bypass
applies only to the launched processes; enforced organizational policy still applies.
The downloaded file is a `.cmd` launcher containing the PowerShell tool. On failure,
the console stays open so the error can be read. Automated callers can pass
`--no-pause` to return the exit code immediately. Organization-enforced script
restrictions still apply.

## App version

The window title and header show the app version. Versions are calculated from
Git as `0.1.<reachable commit count>`, so every new commit in the current history
increases the number. The current four-commit history gives `0.1.4`; the next
commit gives `0.1.5`. The display also includes the first 12 characters of the
commit hash, for example `0.1.4+gc1d80ead76a7`.

Builds with uncommitted or untracked changes are marked `-dev`, for example
`0.1.4-dev+gc1d80ead76a7`. Ignored build artifacts and the driver cache do not mark
a checkout as modified. Rebuilding the same revision does not increment its version.
Commit counts are relative to each branch's history: merges can advance the
number by more than one, and rewriting history can change the count. The commit
identifier distinguishes branches and amended commits with the same count.

The build embeds `version.json` inside the package; the Windows VM does not need
Git and a downloaded package keeps its original version. Rebuild after a commit
to distribute the new version. Building requires Git and a checkout with complete
history. For shallow clones, run `git fetch --unshallow`; CI fetches full history.
A source checkout resolves its version at startup, or shows an explicit development
label if Git metadata is unavailable. No commit hooks or manual version bumps are needed.

## Installing VirtIO drivers

Open **Install drivers**, click **Install VirtIO drivers...**, and complete the
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
src/ToProxmox.ps1             PowerShell entry point and package payload
src/Launch-Package.cmd       Double-click launcher template
src/Launch-Package.ps1       Embedded extraction bootstrap
src/Network/                 Network backend and Windows Forms interface
src/Drivers/                 Driver installation, checks and pinned version
scripts/Package.ps1           Builds the standalone CMD package
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
5.1 and PowerShell 7, checks the CMD launcher using harmless payloads on Windows,
and saves the package as a build artifact. Windows process tests are skipped on Linux.

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
