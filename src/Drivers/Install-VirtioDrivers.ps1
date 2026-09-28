#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Opens the bundled VirtIO Guest Tools installer without automatic reboot.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)][string]$InstallerPath,
    [Parameter(Mandatory = $true)][string]$LogPath,
    [string]$ManifestPath = (Join-Path $PSScriptRoot 'virtio-win.json')
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'VirtioDriverTools.ps1')
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'VirtIO driver installation requires Windows.' }
$os = Get-CimInstance Win32_OperatingSystem
if ([version]$os.Version -lt [version]'10.0') {
    throw 'This driver bundle targets Windows 10/11 and Windows Server 2016 or newer. Older guests need a separately validated driver version.'
}
$architecture = $env:PROCESSOR_ARCHITECTURE
if ($env:PROCESSOR_ARCHITEW6432) { $architecture = $env:PROCESSOR_ARCHITEW6432 }
if ($architecture -notin @('AMD64', 'x86')) { throw 'This VirtIO bundle supports x86 and x64 Windows guests only.' }
$manifest = Read-VirtioManifest -Path $ManifestPath
$InstallerPath = (Resolve-Path -LiteralPath $InstallerPath).ProviderPath
Assert-VirtioInstaller -Path $InstallerPath -Manifest $manifest
$LogPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LogPath)
if ($PSCmdlet.ShouldProcess("VirtIO Guest Tools $($manifest.Version)", 'Open installer for drivers and guest agents')) {
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $LogPath))
    Write-Host "Starting VirtIO Guest Tools $($manifest.Version). Complete the installer window. Log: $LogPath"
    Invoke-VirtioSetup -InstallerPath $InstallerPath -LogPath $LogPath
}
