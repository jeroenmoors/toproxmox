#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Detects and silently removes VMware Tools after migrating a guest to Proxmox.
.DESCRIPTION
On Proxmox/KVM the VMware guest software can no longer reach the VMware host
backdoor and crashes (for example 0xc0000096). This removes VMware Tools through
its MSI product code (msiexec /x /qn /norestart) and reports whether a reboot is
required. It never runs an arbitrary uninstall command.
.EXAMPLE
.\Remove-VmwareTools.ps1 -Mode Check
.EXAMPLE
.\Remove-VmwareTools.ps1 -Mode Remove -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [ValidateSet('Check', 'Remove')][string]$Mode = 'Check',
    [string]$LogPath
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'VmwareToolsTools.ps1')
Invoke-VmwareToolsRemoval @PSBoundParameters
