#Requires -Version 5.1
# Stubbed registry state and msiexec process; never reads the registry or removes
# anything. Safe to run on any OS.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'src/Network/VmwareToolsTools.ps1')
# The engine builds the msiexec path from %SystemRoot%; provide one off-Windows.
if ([string]::IsNullOrEmpty($env:SystemRoot)) { $env:SystemRoot = [IO.Path]::GetTempPath() }

function Assert-VmwareFailure([scriptblock]$Action, [string]$Pattern) {
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_ }
    if ($null -eq $caught -or $caught.Exception.Message -notlike $Pattern) { throw "Expected '$Pattern', got: $caught" }
}
function New-VmwareState([bool]$Installed = $true, [string]$Product = '{11111111-1111-1111-1111-111111111111}', [string]$Version = '12.3.5') {
    if (-not $Installed) { return [PSCustomObject]@{ Installed = $false } }
    [PSCustomObject]@{ Installed = $true; DisplayName = 'VMware Tools'; DisplayVersion = $Version; ProductCode = $Product; UninstallString = 'MsiExec.exe /X' + $Product }
}

$sim = @{ State = (New-VmwareState); Removals = 0; Arguments = ''; ExitCode = 0; ClearOnSuccess = $true }
function Get-VmwareToolsState { return ($sim.State | ConvertTo-Json -Depth 5 | ConvertFrom-Json) }
function Start-Process {
    param($FilePath, $ArgumentList, [switch]$Wait, [switch]$PassThru)
    $sim.Removals++
    $sim.Arguments = ($ArgumentList -join ' ')
    if ($sim.ExitCode -in @(0, 3010) -and $sim.ClearOnSuccess) { $sim.State = New-VmwareState -Installed $false }
    return [PSCustomObject]@{ ExitCode = $sim.ExitCode }
}
try {
    # Not installed: Check and Remove are no-ops.
    $sim.State = New-VmwareState -Installed $false; $sim.Removals = 0
    $result = Invoke-VmwareToolsRemoval -Mode Check
    if ($result.Installed -or $result.Changed) { throw 'Absent VMware Tools should report nothing to remove.' }
    $result = Invoke-VmwareToolsRemoval -Mode Remove -Confirm:$false
    if ($result.Changed -or $sim.Removals -ne 0) { throw 'Absent VMware Tools must not call msiexec.' }

    # Installed: Check plans without removing.
    $sim.State = New-VmwareState; $sim.Removals = 0
    $result = Invoke-VmwareToolsRemoval -Mode Check
    if (-not $result.Installed -or $result.Changed -or $sim.Removals -ne 0 -or $result.Message -notlike '*msiexec /x*') { throw 'Check should plan without removing.' }

    # WhatIf performs no removal.
    Invoke-VmwareToolsRemoval -Mode Remove -WhatIf | Out-Null
    if ($sim.Removals -ne 0) { throw 'WhatIf removed VMware Tools.' }

    # Remove success (exit 0): removed, no reboot, exact product code passed.
    $sim.State = New-VmwareState; $sim.ExitCode = 0; $sim.Removals = 0
    $result = Invoke-VmwareToolsRemoval -Mode Remove -Confirm:$false
    if (-not $result.Changed -or $result.RebootRequired -or $sim.Removals -ne 1) { throw 'Successful removal did not run msiexec exactly once.' }
    if ($sim.Arguments -notlike '*/x {11111111-1111-1111-1111-111111111111}*' -or $sim.Arguments -notlike '*/qn*' -or $sim.Arguments -notlike '*/norestart*') { throw 'msiexec was called with the wrong arguments.' }

    # Remove requesting a reboot (3010): reboot flagged, verification skipped.
    $sim.State = New-VmwareState; $sim.ExitCode = 3010; $sim.Removals = 0
    $result = Invoke-VmwareToolsRemoval -Mode Remove -Confirm:$false
    if (-not $result.Changed -or -not $result.RebootRequired) { throw 'A 3010 result must request a reboot.' }

    # Already absent for the installer (1605): no change, no failure.
    $sim.State = New-VmwareState; $sim.ExitCode = 1605; $sim.Removals = 0
    $result = Invoke-VmwareToolsRemoval -Mode Remove -Confirm:$false
    if ($result.Changed -or $sim.Removals -ne 1) { throw 'Exit 1605 should report nothing removed after one attempt.' }

    # Fatal msiexec error: fail loudly.
    $sim.State = New-VmwareState; $sim.ExitCode = 1603; $sim.Removals = 0
    Assert-VmwareFailure { Invoke-VmwareToolsRemoval -Mode Remove -Confirm:$false } '*removal failed*'

    # Removal reported success but the product is still present: fail loudly.
    $sim.State = New-VmwareState; $sim.ExitCode = 0; $sim.ClearOnSuccess = $false; $sim.Removals = 0
    Assert-VmwareFailure { Invoke-VmwareToolsRemoval -Mode Remove -Confirm:$false } '*still appears installed*'
    $sim.ClearOnSuccess = $true

    # Installed without an MSI product code: refuse rather than run an arbitrary command.
    $sim.State = New-VmwareState -Product ''; $sim.Removals = 0
    Assert-VmwareFailure { Invoke-VmwareToolsRemoval -Mode Remove -Confirm:$false } '*no MSI product code*'
    if ($sim.Removals -ne 0) { throw 'A missing product code must not call msiexec.' }

    Write-Host 'OK: VMware Tools detection, planning, WhatIf, silent removal, reboot handling, verification and blocked states.'
} finally {
    Remove-Item Function:\Get-VmwareToolsState -ErrorAction SilentlyContinue
    Remove-Item Function:\Start-Process -ErrorAction SilentlyContinue
}
