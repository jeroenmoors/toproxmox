# Preparing the Windows storage driver before migration

Use **Boot preparation** after installing the VirtIO drivers on the source VM,
completing any installer-requested restart, and before shutting down for migration.
Select the controller that will host the Windows boot disk on Proxmox:

| Target controller | Windows storage service |
| --- | --- |
| VirtIO SCSI or VirtIO SCSI single | `vioscsi` |
| VirtIO Block | `viostor` |

1. Click **1. Check boot settings**. This reads the installed driver configuration
   and prints the proposed changes in the log without modifying the registry.
2. Review the result and click **2. Prepare boot settings...** to apply it.
3. Keep the backup files and shut down the source VM for migration. If Windows
   boots on VMware again, recheck immediately before the final shutdown.
4. Validate booting and devices on the migrated VM through the Proxmox console.

The operation sets the selected service's existing `Start` REG_DWORD to `0`
(Boot Start). If an existing `StartOverride` subkey has a REG_DWORD value named
`0`, that value is also set to `0`. Other override values are preserved; unexpected
values and nonzero overrides for other profiles block automatic preparation.
Absent override keys/values are not created. Already prepared settings are left
unchanged, without generating another backup.

Checks require an existing service registered as a kernel driver in the
`SCSI miniport` group, an existing supported `Start` value, and the registered
`vioscsi.sys` or `viostor.sys` binary under the Windows directory. Files in the
Windows DriverStore are accepted when the service points there. A package that
was merely staged, without registering the driver service, is insufficient:
ToProxmox reports this and does not fabricate a service by creating registry keys.
Repair the installation or use the compatible-controller migration procedure below.

## Why NetKVM is not changed

Demand Start (`3`) does not mean a Plug and Play driver is disabled. Windows can
load it when matching hardware is detected. NetKVM's upstream INF intentionally
uses Demand Start and the NDIS load-order group. It is the network driver, not the
storage driver needed to read a local Windows boot disk. This operation therefore
never sets `NetKVM\Start` to `0`. Network boot/iSCSI scenarios require a separate
procedure and are outside this feature.

The upstream `vioscsi` and `viostor` INFs already request Boot Start. Do not assume
that every VMware guest needs a registry change: inspect the actual installed
state, including any startup override.

## Backup and failure handling

Before the first registry write, ToProxmox saves:

- A JSON snapshot containing the service state and proposed changes.
- A `.reg` file containing only the original values that will be changed.

In the UI, both files are stored in the operation's persistent directory under
`C:\ProgramData\NetworkMigration\Logs`. CLI runs default to
`C:\ProgramData\NetworkMigration\BootBackups`. Failure to save either backup
stops the operation before registry writes. The service is read again before
changes and verified afterward. A write failure can leave a partial change;
the error reports the retained backup paths.

The `.reg` file supports manual restoration on the original VM using Registry
Editor or `reg.exe import <backup.reg>` from an elevated prompt. Restore startup
values only while the boot disk uses a compatible controller. Restoring Demand
Start or Disabled while Windows depends on VirtIO storage can make it unbootable.
These files are not a full VM backup and do not reinstall drivers.

## Command line

Run inside the Windows VM in an elevated PowerShell session:

```powershell
.\src\Drivers\Prepare-VirtioBoot.ps1 -Mode Check -Service vioscsi
.\src\Drivers\Prepare-VirtioBoot.ps1 -Mode Prepare -Service vioscsi -WhatIf
.\src\Drivers\Prepare-VirtioBoot.ps1 -Mode Prepare -Service vioscsi
```

Use `-Service viostor` only for a VirtIO Block boot disk. `-WhatIf` performs no
registry writes and creates no backups. The scripts are included in both regular
and `-SkipDrivers` packages; preparation can also inspect drivers installed using
an external ISO.

## Limits and fallback

This checks and prepares registry startup settings; it does not prove that the
driver supports the destination hardware, passes signature enforcement, or will
successfully boot. It does not install a missing driver, change the current boot
controller, activate a missing device, alter BCD, or change Proxmox hardware.

If the migrated guest cannot boot with VirtIO storage, use a compatible IDE/SATA
boot controller, expose a temporary disk on the intended VirtIO controller,
install and verify its driver, then shut down and switch the boot disk controller.
Keep the source VM stopped while the migrated copy uses the production network.

Automated tests use simulated service state and writes. Real Windows registry,
UI, and VMware-to-Proxmox boot validation must be performed on a test VM.

References:

- [Microsoft service startup values](https://learn.microsoft.com/en-us/windows-hardware/drivers/install/hklm-system-currentcontrolset-services-registry-tree)
- [Microsoft boot-start drivers](https://learn.microsoft.com/en-us/windows-hardware/drivers/install/installing-a-boot-start-driver)
- [VirtIO SCSI service definition](https://github.com/virtio-win/kvm-guest-drivers-windows/blob/master/vioscsi/vioscsi.inx)
- [VirtIO Block service definition](https://github.com/virtio-win/kvm-guest-drivers-windows/blob/master/viostor/viostor.inx)
- [NetKVM service definition](https://github.com/virtio-win/kvm-guest-drivers-windows/blob/master/NetKVM/netkvm-base.txt)
- [Proxmox migration guide](https://pve.proxmox.com/wiki/Migrate_to_Proxmox_VE)
