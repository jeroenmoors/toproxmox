#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Checks or prepares an installed VirtIO storage driver for boot before migration.
.EXAMPLE
.\Prepare-VirtioBoot.ps1 -Mode Check -Service vioscsi
.EXAMPLE
.\Prepare-VirtioBoot.ps1 -Mode Prepare -Service vioscsi -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [ValidateSet('Check', 'Prepare')][string]$Mode = 'Check',
    [ValidateSet('vioscsi', 'viostor')][string]$Service = 'vioscsi',
    [string]$BackupDirectory = (Join-Path $env:ProgramData 'NetworkMigration/BootBackups')
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'VirtioBootTools.ps1')
# Forward common WhatIf/Confirm parameters; the helper owns the actual write boundary.
$PSBoundParameters['BackupDirectory'] = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($BackupDirectory)
Invoke-VirtioBootPreparation @PSBoundParameters
