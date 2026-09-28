# ToProxmox

A PowerShell tool that simplifies migrating Windows VMs to Proxmox.
The initial functionality exports and restores IPv4 network settings through a
Windows Forms interface. Copying or converting virtual disks and creating Proxmox
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

Build with Windows PowerShell 5.1 or PowerShell 7. No external modules are required:

```powershell
.\build.ps1 package
# Optional: .\build.ps1 package -OutputDirectory C:\Build\ToProxmox
```

This creates **`dist/ToProxmox.ps1`**, the only file users need to download.
Run the downloaded file inside the Windows VM:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ToProxmox.ps1
```

The package embeds the interface and backend as Base64 data. After elevation, if
needed, it extracts them into a unique temporary directory, waits for the interface
to close, and removes the temporary files. No downloads are required at startup.
Exports and logs are stored outside the temporary directory. ExecutionPolicy Bypass
applies only to the launched processes; enforced organizational policy still applies.
The file is a PowerShell script, not an `.exe`.

## Development

```text
AGENTS.md                    Project language instructions
src/ToProxmox.ps1             Main launcher and package template
src/Network/                 Network backend and Windows Forms interface
scripts/Package.ps1           Builds the standalone script
build.ps1                    Package and test commands
tests/Test-Package.ps1        Build checks without external test modules
docs/network-migration.txt   Network migration guide
dist/                        Generated distribution (excluded from Git)
```

Edit the application code under `src`.

```powershell
.\build.ps1 test
```

The tests check PowerShell syntax, exact embedding of source file bytes, paths
containing spaces, and reproducible builds. They do not launch the interface or
change network settings. GitHub Actions runs these checks with Windows PowerShell
5.1 and PowerShell 7 and saves the package as a build artifact.

## Migrating network settings

1. Export the network settings before migration; keep a copy of the JSON file outside the VM.
2. After migration, install the target NIC driver and open ToProxmox through the Proxmox console.
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
