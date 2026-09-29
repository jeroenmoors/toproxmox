#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Registers a staged VirtIO storage driver as a device so its boot service exists.
.DESCRIPTION
On VMware the VirtIO controller is absent, so the Guest Tools installer only stages
the vioscsi/viostor package without creating its kernel service. This mirrors the
"Add legacy hardware" wizard: it creates a root-enumerated device for the driver's
hardware ID and force-installs the staged package, which registers the service.
Run this before Prepare-VirtioBoot.ps1.
.EXAMPLE
.\Register-VirtioStorage.ps1 -Mode Check -Service vioscsi
.EXAMPLE
.\Register-VirtioStorage.ps1 -Mode Register -Service vioscsi -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [ValidateSet('Check', 'Register')][string]$Mode = 'Check',
    [ValidateSet('vioscsi', 'viostor')][string]$Service = 'vioscsi'
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'VirtioBootTools.ps1')
. (Join-Path $PSScriptRoot 'VirtioStorageDeviceTools.ps1')
Invoke-VirtioStorageRegistration @PSBoundParameters
