#Requires -Version 5.1
<#
.SYNOPSIS
Builds or checks the single-file ToProxmox distribution.
.EXAMPLE
.\build.ps1 package
.EXAMPLE
.\build.ps1 test
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('package', 'test')]
    [string]$Command = 'package',
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'dist'),
    [switch]$SkipDrivers,
    [string]$DriverInstallerPath
)
$ErrorActionPreference = 'Stop'
if ($Command -eq 'test') {
    & (Join-Path $PSScriptRoot 'tests/Test-Package.ps1')
    & (Join-Path $PSScriptRoot 'tests/Test-Drivers.ps1')
    & (Join-Path $PSScriptRoot 'tests/Test-VirtioBoot.ps1')
} else {
    & (Join-Path $PSScriptRoot 'scripts/Package.ps1') -OutputDirectory $OutputDirectory -SkipDrivers:$SkipDrivers -DriverInstallerPath $DriverInstallerPath
}
