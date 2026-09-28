#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Export/restore IPv4 network settings for a VMware to Proxmox migration.
.DESCRIPTION
Run in Windows PowerShell as Administrator inside the VM. Restore from the
Proxmox console, not RDP. Install the destination NIC driver first.

Export is read-only for networking and refuses to overwrite an existing file.
Restore changes ONE explicitly selected adapter and saves its previous settings
beside the export. -WhatIf previews the operation without writing or changing it.

Scope: ordinary NICs, IPv4 static addresses (including SkipAsSource), DHCP,
default gateways and route metrics, IPv4 DNS mode/order, DNS suffix/registration,
interface metric and IPv4 MTU. Does not migrate NIC names, VLAN tagging, teaming,
IPv6, firewall profiles, NRPT/GPO, or advanced NIC settings. Extra manual routes
and manual IPv6 addresses cause restore to stop for separate review.
An exported DHCP lease is information only: the DHCP server assigns the new IP.
Optional -RemoveOldAdapter removes ONLY the source PnP instance recorded by a
fresh export from this version, and only when it is absent (not merely disabled
or disconnected). Requires PnPUtil /remove-device (Windows Server 2022/2025,
Windows 10 2004+ or Windows 11). Older systems must remove the verified absent
NIC in Device Manager. Driver packages are not removed. A required reboot stops
restore: reboot and rerun. Export files without PnpInstanceId still work without
this switch; never overwrite the original export from inside the migrated VM.
Never run the source and migrated VM simultaneously on the production network.

.EXAMPLE
.\Migrate-Network.ps1 -Mode Export
.EXAMPLE
.\Migrate-Network.ps1 -Mode List
.EXAMPLE
.\Migrate-Network.ps1 -Mode Restore -SourceAlias Ethernet0 -TargetAlias Ethernet -WhatIf
.EXAMPLE
.\Migrate-Network.ps1 -Mode Restore -SourceAlias Ethernet0 -TargetAlias Ethernet
.EXAMPLE
.\Migrate-Network.ps1 -Mode Restore -SourceAlias Ethernet0 -TargetAlias Ethernet -RemoveOldAdapter -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Export', 'List', 'Restore')][string]$Mode,
    [string]$Path = 'C:\Migration\network.json',
    [string]$SourceAlias,
    [string]$TargetAlias,
    [switch]$RemoveOldAdapter
)
$ErrorActionPreference = 'Stop'

function Read-AdapterSettings($Adapter) {
    $idx = $Adapter.ifIndex
    $iface = Get-NetIPInterface -InterfaceIndex $idx -AddressFamily IPv4
    $dns = Get-DnsClientServerAddress -InterfaceIndex $idx -AddressFamily IPv4
    $client = Get-DnsClient -InterfaceIndex $idx
    $guid = ([guid]$Adapter.InterfaceGuid).ToString('B')
    $hardware = @(Get-CimInstance Win32_NetworkAdapter | Where-Object {
        $_.GUID -and ([guid]$_.GUID) -eq ([guid]$guid)
    })
    $pnpId = if ($hardware.Count -eq 1) { [string]$hardware[0].PNPDeviceID } else { '' }
    $reg = Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$guid"
    $manualDns = -not [string]::IsNullOrWhiteSpace([string]$reg.NameServer)
    $ip = @(Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4)
    $routes = @(Get-NetRoute -InterfaceIndex $idx -AddressFamily IPv4)
    $v6 = @(Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv6 -ErrorAction SilentlyContinue |
        Where-Object { $_.PrefixOrigin -eq 'Manual' -and $_.IPAddress -ne '::1' })
    [PSCustomObject]@{
        Alias = $Adapter.Name
        Description = $Adapter.InterfaceDescription
        MacAddress = $Adapter.MacAddress
        InterfaceGuid = $guid
        PnpInstanceId = $pnpId
        Dhcp = [string]$iface.Dhcp
        ObservedIPv4 = @($ip | Select-Object IPAddress, PrefixLength)
        StaticIPv4 = @($ip | Where-Object { $_.PrefixOrigin -eq 'Manual' } |
            Select-Object IPAddress, PrefixLength, SkipAsSource)
        Gateways = @($routes | Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' -and $_.Protocol -eq 'NetMgmt' } |
            Select-Object NextHop, RouteMetric)
        ExtraRoutes = @($routes | Where-Object { $_.DestinationPrefix -ne '0.0.0.0/0' -and $_.Protocol -eq 'NetMgmt' } |
            Select-Object DestinationPrefix, NextHop, RouteMetric)
        ManualIPv6 = @($v6 | Select-Object IPAddress, PrefixLength)
        DnsMode = $(if ($manualDns) { 'Static' } else { 'Automatic' })
        DnsServers = @($dns.ServerAddresses)
        DnsSuffix = [string]$client.ConnectionSpecificSuffix
        RegisterDns = [bool]$client.RegisterThisConnectionsAddress
        UseSuffix = [bool]$client.UseSuffixWhenRegistering
        AutomaticMetric = [string]$iface.AutomaticMetric
        InterfaceMetric = [int]$iface.InterfaceMetric
        Mtu = [int]$iface.NlMtu
    }
}

# Enumerate successfully before deciding a device is absent. Status Unknown,
# Disabled, or a disconnected cable is NOT sufficient evidence of absence.
function Assert-SourceDeviceAbsent([string]$InstanceId) {
    $present = @(Get-PnpDevice -Class Net -PresentOnly)
    if (@($present | Where-Object { $_.InstanceId -eq $InstanceId }).Count -gt 0) {
        throw 'The original adapter is still physically present. Refusing to remove it, even if disabled/disconnected.'
    }
}

function Assert-NoOtherIPConflicts($Settings, [int]$TargetIndex, [int[]]$IgnoreIndexes = @()) {
    $otherIPs = @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object {
        $_.InterfaceIndex -ne $TargetIndex -and $IgnoreIndexes -notcontains $_.InterfaceIndex
    })
    foreach ($address in $Settings.StaticIPv4) {
        if ($otherIPs.IPAddress -contains $address.IPAddress) {
            throw "IP $($address.IPAddress) is still assigned to another interface. Resolve this before restoring."
        }
    }
}

if ($RemoveOldAdapter -and $Mode -ne 'Restore') { throw '-RemoveOldAdapter is only valid with -Mode Restore.' }
$Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
if ($Mode -eq 'Export') {
    if (Test-Path -LiteralPath $Path) { throw "Export already exists: $Path. Choose another -Path to keep the original safe." }
    $items = @(Get-NetAdapter -Physical | ForEach-Object { Read-AdapterSettings $_ })
    if ($items.Count -eq 0) { throw 'No physical/hardware NICs found. Review NIC teaming/virtual switches separately.' }
    if ($PSCmdlet.ShouldProcess($Path, 'Write network export')) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
        [PSCustomObject]@{
            SchemaVersion = 1
            ComputerName = $env:COMPUTERNAME
            ExportedAt = (Get-Date).ToString('o')
            Adapters = $items
        } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding UTF8
        Write-Host "Saved: $Path. Copy this file outside the VM as well."
        $items | Format-Table Alias, MacAddress, Dhcp, DnsMode
    }
    return
}

$saved = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
if ($saved.SchemaVersion -ne 1) { throw 'Unsupported export schema.' }
if ($Mode -eq 'List') {
    Write-Host 'SOURCE adapters in export:'
    $saved.Adapters | Format-Table Alias, Description, MacAddress, Dhcp
    Write-Host 'CURRENT adapters (verify MAC/VLAN mapping in Proxmox):'
    Get-NetAdapter -Physical | Format-Table Name, InterfaceDescription, MacAddress, Status, ifIndex
    return
}
if ($saved.ComputerName -ne $env:COMPUTERNAME) { throw 'This export belongs to another computer.' }
if (-not $SourceAlias -or -not $TargetAlias) { throw 'Restore requires -SourceAlias and -TargetAlias. Use -Mode List first.' }
$sources = @($saved.Adapters | Where-Object { $_.Alias -eq $SourceAlias })
$targets = @(Get-NetAdapter -Physical | Where-Object { $_.Name -eq $TargetAlias })
if ($sources.Count -ne 1 -or $targets.Count -ne 1) { throw 'Source or target does not resolve to exactly one adapter.' }
$src = $sources[0]
$target = $targets[0]
$idx = $target.ifIndex
if ($target.Status -eq 'Disabled') { throw 'Enable the target adapter first.' }
$before = Read-AdapterSettings $target
foreach ($settings in @($src, $before)) {
    if (@($settings.ExtraRoutes).Count -gt 0 -or @($settings.ManualIPv6).Count -gt 0) {
        throw 'Source or target has extra manual routes or manual IPv6. Use a tailored migration procedure.'
    }
    if ($settings.Dhcp -eq 'Enabled' -and (@($settings.StaticIPv4).Count -gt 0 -or @($settings.Gateways).Count -gt 0)) {
        throw 'Mixed DHCP and manual IPv4 settings require a tailored migration procedure.'
    }
}
if ($src.Dhcp -eq 'Disabled' -and @($src.StaticIPv4).Count -eq 0) { throw 'No static IPv4 addresses to restore.' }
if ($src.DnsMode -eq 'Static' -and @($src.DnsServers).Count -eq 0) { throw 'Static DNS mode without server addresses.' }
$oldDevice = $null
$oldIndexes = @()
$pnpUtil = $null
if ($RemoveOldAdapter) {
    if ([string]::IsNullOrWhiteSpace([string]$src.PnpInstanceId)) {
        throw 'Export lacks PnpInstanceId. Before migration, export again with this version to a NEW -Path. If already migrated, remove the verified absent adapter manually; do not replace the original export.'
    }
    if ([guid]$src.InterfaceGuid -eq [guid]$target.InterfaceGuid -or $src.PnpInstanceId -eq $before.PnpInstanceId) {
        throw 'The selected source is the target adapter. Refusing removal.'
    }
    if ([string]$src.PnpInstanceId -match '[*?]') { throw 'Wildcard device identifiers are not allowed.' }
    $devices = @(Get-PnpDevice -Class Net)
    $matches = @($devices | Where-Object { $_.InstanceId -eq $src.PnpInstanceId })
    if ($matches.Count -gt 1) { throw 'Ambiguous device identity; no changes made.' }
    Assert-SourceDeviceAbsent $src.PnpInstanceId
    if ($matches.Count -eq 1) {
        $oldDevice = $matches[0]
        $oldIndexes = @(Get-NetAdapter -IncludeHidden | Where-Object {
            $_.InterfaceGuid -and ([guid]$_.InterfaceGuid) -eq ([guid]$src.InterfaceGuid)
        } | ForEach-Object { [int]$_.ifIndex })
        $pnpUtil = Join-Path $env:SystemRoot 'System32\pnputil.exe'
        if (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'Sysnative\pnputil.exe')) {
            $pnpUtil = Join-Path $env:SystemRoot 'Sysnative\pnputil.exe'
        }
        $helpText = (& $pnpUtil /? | Out-String)
        if ($helpText -notmatch '/remove-device') {
            throw 'This Windows version lacks pnputil /remove-device. Remove only the verified absent NIC manually in Device Manager, then restore without -RemoveOldAdapter.'
        }
        Write-Host "Verified absent source adapter: $($oldDevice.FriendlyName)"
        Write-Host "Exact PnP instance to remove: $($src.PnpInstanceId)"
    } else {
        Write-Host 'Source PnP instance is already absent from the device inventory; no removal needed.'
    }
}
Assert-NoOtherIPConflicts -Settings $src -TargetIndex $idx -IgnoreIndexes $oldIndexes

Write-Host "Restore '$SourceAlias' to '$TargetAlias' (MAC $($target.MacAddress), index $idx)"
Write-Host "IPv4 mode: $($src.Dhcp); DNS: $($src.DnsMode); suffix: $($src.DnsSuffix)"
$src.StaticIPv4 | Format-Table IPAddress, PrefixLength, SkipAsSource
$src.Gateways | Format-Table NextHop, RouteMetric
Write-Host ('DNS servers: ' + ($src.DnsServers -join ', '))
$action = 'Replace IPv4 settings; existing network connections will be interrupted'
if ($null -ne $oldDevice) { $action = "Remove absent source device '$($src.PnpInstanceId)', then $action" }
if (-not $PSCmdlet.ShouldProcess($TargetAlias, $action)) { return }

$backupPath = "$Path.before-restore-$(Get-Date -Format yyyyMMdd-HHmmss)-$([guid]::NewGuid().ToString('N')).json"
[PSCustomObject]@{
    SchemaVersion = 1; ComputerName = $env:COMPUTERNAME
    ExportedAt = (Get-Date).ToString('o'); Adapters = @($before)
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $backupPath -Encoding UTF8
Write-Host "Target backup: $backupPath"

try {
    if ($null -ne $oldDevice) {
        # Recheck presence immediately before the one exact native removal call.
        Assert-SourceDeviceAbsent $src.PnpInstanceId
        & $pnpUtil /remove-device ([string]$src.PnpInstanceId) | Out-Host
        $removeExitCode = $LASTEXITCODE
        if ($removeExitCode -eq 3010) {
            throw 'Device removal requires a reboot. Reboot from the console, then rerun restore. Target IP settings have not yet been changed.'
        }
        if ($removeExitCode -ne 0) { throw "Device removal failed (exit $removeExitCode). Target IP settings have not yet been changed." }
        $remaining = @(Get-PnpDevice -Class Net | Where-Object { $_.InstanceId -eq $src.PnpInstanceId })
        if ($remaining.Count -gt 0) { throw 'Old device is still listed after removal. Reboot and check before retrying; target IP settings have not yet been changed.' }
    }
    # A second check catches any other/stale interface assignment after removal.
    Assert-NoOtherIPConflicts -Settings $src -TargetIndex $idx
    Set-NetIPInterface -InterfaceIndex $idx -AddressFamily IPv4 -Dhcp Disabled
    # Remove persistent entries first, then any remaining active entries.
    foreach ($store in @('PersistentStore', 'ActiveStore')) {
        Get-NetRoute -InterfaceIndex $idx -AddressFamily IPv4 -PolicyStore $store -ErrorAction SilentlyContinue |
            Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' } |
            Remove-NetRoute -Confirm:$false
        Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -PolicyStore $store -ErrorAction SilentlyContinue |
            Where-Object { $_.PrefixOrigin -eq 'Manual' } |
            Remove-NetIPAddress -Confirm:$false
    }
    if ($src.Dhcp -eq 'Enabled') {
        Set-NetIPInterface -InterfaceIndex $idx -AddressFamily IPv4 -Dhcp Enabled
    } else {
        foreach ($address in $src.StaticIPv4) {
            New-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -IPAddress $address.IPAddress `
                -PrefixLength $address.PrefixLength -SkipAsSource ([bool]$address.SkipAsSource) | Out-Null
        }
        foreach ($gateway in $src.Gateways) {
            New-NetRoute -InterfaceIndex $idx -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' `
                -NextHop $gateway.NextHop -RouteMetric $gateway.RouteMetric | Out-Null
        }
    }
    # CIM input limits DNS changes to the IPv4 server-address instance.
    $dnsTarget = Get-DnsClientServerAddress -InterfaceIndex $idx -AddressFamily IPv4
    if ($src.DnsMode -eq 'Static') {
        $dnsTarget | Set-DnsClientServerAddress -ServerAddresses ([string[]]$src.DnsServers)
    } else {
        $dnsTarget | Set-DnsClientServerAddress -ResetServerAddresses
    }
    Set-DnsClient -InterfaceIndex $idx -ConnectionSpecificSuffix ([string]$src.DnsSuffix) `
        -RegisterThisConnectionsAddress ([bool]$src.RegisterDns) -UseSuffixWhenRegistering ([bool]$src.UseSuffix)
    if ($src.AutomaticMetric -eq 'Enabled') {
        Set-NetIPInterface -InterfaceIndex $idx -AddressFamily IPv4 -AutomaticMetric Enabled -NlMtuBytes $src.Mtu
    } else {
        Set-NetIPInterface -InterfaceIndex $idx -AddressFamily IPv4 -AutomaticMetric Disabled `
            -InterfaceMetric $src.InterfaceMetric -NlMtuBytes $src.Mtu
    }
} catch {
    Write-Warning "Restore stopped; settings may be partially applied. Stay on the console. Backup: $backupPath"
    throw
}
Write-Host 'Settings applied. Verify DHCP lease/address state, routes, DNS, network profile and application access.'
Write-Host 'Reboot the VM and verify again before accepting the migration.'
Get-NetIPConfiguration -InterfaceIndex $idx
