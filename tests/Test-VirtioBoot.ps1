#Requires -Version 5.1
# Simulated service snapshots and writes; never touches the Windows registry.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'src/Drivers/VirtioBootTools.ps1')
function Assert-BootFailure([scriptblock]$Action, [string]$Pattern) {
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_ }
    if ($null -eq $caught -or $caught.Exception.Message -notlike $Pattern) { throw "Expected '$Pattern', got: $caught" }
}
function New-BootFixture([string]$Service = 'vioscsi', [int]$Start = 3) {
    [PSCustomObject]@{
        Service = $Service; Exists = $true
        Start = [PSCustomObject]@{ Name = 'Start'; Kind = 'DWord'; Value = $Start }
        Type = [PSCustomObject]@{ Name = 'Type'; Kind = 'DWord'; Value = 1 }
        Group = 'SCSI miniport'; ImagePath = "System32\drivers\$Service.sys"
        DriverPath = "C:\Windows\System32\drivers\$Service.sys"; DriverIssue = ''; DriverFilePresent = $true
        Overrides = @([PSCustomObject]@{ Name = '0'; Kind = 'DWord'; Value = 3 })
    }
}
$temp = Join-Path ([IO.Path]::GetTempPath()) ('ToProxmox-boot-test-' + [guid]::NewGuid().ToString('N'))
try {
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $expected = Join-Path $env:SystemRoot 'System32\drivers\vioscsi.sys'
        foreach ($path in @('System32\drivers\vioscsi.sys', '\SystemRoot\System32\drivers\vioscsi.sys',
            '%SystemRoot%\System32\drivers\vioscsi.sys', $expected, ('\??\' + $expected))) {
            if ((Resolve-VirtioDriverPath -ImagePath $path -Service vioscsi) -ine $expected) { throw 'Driver path normalization failed.' }
        }
        Assert-BootFailure { Resolve-VirtioDriverPath -ImagePath 'C:\Other\vioscsi.sys' -Service vioscsi } '*outside*'
        Assert-BootFailure { Resolve-VirtioDriverPath -ImagePath 'System32\drivers\NetKVM.sys' -Service vioscsi } '*Unexpected*'
    }
    foreach ($service in @('vioscsi', 'viostor')) {
        foreach ($start in @(0, 1, 2, 3, 4)) {
            $plan = Get-VirtioBootPlan (New-BootFixture $service $start)
            if (-not $plan.CanPrepare -or $plan.AlreadyPrepared -or @($plan.Changes | Where-Object Name -eq '0').Count -ne 1) {
                throw 'A valid storage start/override was not planned correctly.'
            }
        }
    }
    $state = New-BootFixture -Start 0
    $state.Overrides = @()
    $plan = Get-VirtioBootPlan $state
    if (-not $plan.AlreadyPrepared -or $plan.Changes.Count -ne 0) { throw 'An absent override should not be created.' }
    $state.Overrides = @([PSCustomObject]@{ Name = '0'; Kind = 'DWord'; Value = 0 })
    if (-not (Get-VirtioBootPlan $state).AlreadyPrepared) { throw 'Zero startup values are not idempotent.' }

    $state = New-BootFixture
    $state.Exists = $false
    if ((Get-VirtioBootPlan $state).CanPrepare) { throw 'Missing services must be rejected.' }
    $state = New-BootFixture; $state.DriverFilePresent = $false
    if ((Get-VirtioBootPlan $state).CanPrepare) { throw 'Missing binaries must be rejected.' }
    $state = New-BootFixture; $state.DriverIssue = 'Unexpected binary path'
    if ((Get-VirtioBootPlan $state).CanPrepare) { throw 'Unexpected binaries must be rejected.' }
    $state = New-BootFixture; $state.Start.Kind = 'String'
    if ((Get-VirtioBootPlan $state).CanPrepare) { throw 'Non-DWORD Start must be rejected.' }
    $state = New-BootFixture; $state.Start = $null
    if ((Get-VirtioBootPlan $state).CanPrepare) { throw 'Missing Start must be rejected.' }
    $state = New-BootFixture; $state.Type.Value = 16
    if ((Get-VirtioBootPlan $state).CanPrepare) { throw 'Non-driver services must be rejected.' }
    $state = New-BootFixture; $state.Group = 'NDIS'
    if ((Get-VirtioBootPlan $state).CanPrepare) { throw 'Non-storage groups must be rejected.' }
    $state = New-BootFixture; $state.Overrides[0].Kind = 'String'
    if ((Get-VirtioBootPlan $state).CanPrepare) { throw 'Invalid override types must be rejected.' }
    $state = New-BootFixture; $state.Overrides[0].Name = '1'
    if ((Get-VirtioBootPlan $state).CanPrepare) { throw 'Other nonzero override profiles require manual review.' }
    $state = New-BootFixture; $state.Service = 'NetKVM'
    Assert-BootFailure { Get-VirtioBootPlan $state } '*Only VirtIO storage*'

    # Registry effects are replaced with in-memory snapshots; backup files are real.
    $simulation = @{ State = (New-BootFixture); Writes = 0; Reads = 0; FailAt = 0; ChangeOnRead = 0 }
    function Get-VirtioBootState {
        param($Service)
        $simulation.Reads++
        if ($simulation.ChangeOnRead -eq $simulation.Reads) { $simulation.State.Start.Value = 4 }
        return ($simulation.State | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
    }
    function Set-VirtioBootValue {
        param($Service, $Change)
        $simulation.Writes++
        if (@(Get-ChildItem -LiteralPath $temp -Filter '*.reg' -Recurse).Count -eq 0) { throw 'Write occurred before backup.' }
        if ($simulation.FailAt -eq $simulation.Writes) { throw 'Simulated registry access failure' }
        if ($Service -ne $simulation.State.Service) { throw 'Wrong storage driver selected.' }
        if ($Change.SubKey -eq '') { $simulation.State.Start.Value = 0 }
        elseif ($Change.SubKey -eq 'StartOverride' -and $Change.Name -eq '0') { $simulation.State.Overrides[0].Value = 0 }
        else { throw 'Unexpected registry write.' }
    }
    $null = Invoke-VirtioBootPreparation -Mode Check -BackupDirectory $temp
    $null = Invoke-VirtioBootPreparation -Mode Prepare -BackupDirectory $temp -WhatIf
    if ($simulation.Writes -ne 0 -or (Test-Path $temp)) { throw 'Check or WhatIf had side effects.' }
    $result = Invoke-VirtioBootPreparation -Mode Prepare -BackupDirectory $temp -Confirm:$false
    if (-not $result.Changed -or $simulation.Writes -ne 2) { throw 'The two required startup writes were not applied.' }
    $backup = Get-Content -LiteralPath ($result.BackupPath + '.json') -Raw | ConvertFrom-Json
    if ($backup.State.Start.Value -ne 3 -or $backup.State.Overrides[0].Value -ne 3) { throw 'Original values were not backed up.' }
    $reg = [IO.File]::ReadAllText($result.BackupPath + '.reg')
    if ($reg -notmatch '"Start"=dword:00000003' -or $reg -notmatch '"0"=dword:00000003' -or $reg -match 'NetKVM') {
        throw 'The restore file does not preserve exactly the changed storage values.'
    }
    $count = @(Get-ChildItem -LiteralPath $temp -File).Count
    $result = Invoke-VirtioBootPreparation -Mode Prepare -BackupDirectory $temp -Confirm:$false
    if ($result.Changed -or $simulation.Writes -ne 2 -or @(Get-ChildItem -LiteralPath $temp -File).Count -ne $count) {
        throw 'An already prepared driver caused new writes or backups.'
    }
    $simulation.State = New-BootFixture; $simulation.Writes = 0
    $blockedDirectory = Join-Path $temp 'not-a-directory'
    [IO.File]::WriteAllText($blockedDirectory, 'block directory creation')
    Assert-BootFailure { Invoke-VirtioBootPreparation -Mode Prepare -BackupDirectory $blockedDirectory -Confirm:$false } '*'
    if ($simulation.Writes -ne 0) { throw 'Registry was changed despite backup failure.' }
    $simulation.State = New-BootFixture; $simulation.Writes = 0; $simulation.Reads = 0; $simulation.ChangeOnRead = 2
    Assert-BootFailure { Invoke-VirtioBootPreparation -Mode Prepare -BackupDirectory $temp -Confirm:$false } '*state changed*'
    if ($simulation.Writes -ne 0) { throw 'A stale state was modified.' }
    $simulation.ChangeOnRead = 0; $simulation.State = New-BootFixture; $simulation.FailAt = 2
    Assert-BootFailure { Invoke-VirtioBootPreparation -Mode Prepare -BackupDirectory $temp -Confirm:$false } '*partially changed*Backup:*'
    if ($simulation.State.Start.Value -ne 0 -or $simulation.State.Overrides[0].Value -ne 3) { throw 'Partial failure simulation did not run.' }
    if (@(Get-ChildItem -LiteralPath $temp -Filter '*.reg').Count -ne 2) { throw 'Failure did not retain a restore file.' }
    $simulation.State = New-BootFixture; $simulation.State.Exists = $false; $simulation.Writes = 0
    Assert-BootFailure { Invoke-VirtioBootPreparation -Mode Prepare -BackupDirectory $temp -Confirm:$false } '*service is missing*'
    if ($simulation.Writes -ne 0) { throw 'A missing service was modified.' }
    Write-Host 'OK: storage startup/override plans, missing drivers, NetKVM exclusion, read-only checks, WhatIf, backups, stale state, idempotence and partial failures.'
} finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
