#Requires -Version 5.1
# Loading these functions never reads or changes the registry.
function Get-VirtioRegistryValue($Key, [string]$Name) {
    if ($Key.GetValueNames() -notcontains $Name) { return $null }
    [PSCustomObject]@{
        Name = $Name
        Kind = [string]$Key.GetValueKind($Name)
        Value = $Key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    }
}

function Resolve-VirtioDriverPath {
    param([string]$ImagePath, [ValidateSet('vioscsi', 'viostor')][string]$Service)
    $path = [Environment]::ExpandEnvironmentVariables($ImagePath).Trim('"')
    if ($path.StartsWith('\??\')) { $path = $path.Substring(4) }
    if ($path.StartsWith('\SystemRoot\', [StringComparison]::OrdinalIgnoreCase)) {
        $path = $env:SystemRoot + $path.Substring(11)
    } elseif ($path.StartsWith('System32\', [StringComparison]::OrdinalIgnoreCase)) {
        $path = $env:SystemRoot + '\' + $path
    }
    if ($path -notmatch '^[A-Za-z]:\\' -or [IO.Path]::GetFileName($path) -ine "$Service.sys") {
        throw "Unexpected ImagePath for $Service. Repair the installed storage driver first."
    }
    $path = [IO.Path]::GetFullPath($path)
    if (-not $path.StartsWith(($env:SystemRoot.TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) {
        throw "The $Service driver binary is outside the Windows directory. Review it manually."
    }
    return $path
}

function Get-VirtioBootState {
    param([ValidateSet('vioscsi', 'viostor')][string]$Service = 'vioscsi')
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Boot preparation requires Windows.' }
    $view = if ([Environment]::Is64BitOperatingSystem) { [Microsoft.Win32.RegistryView]::Registry64 } else { [Microsoft.Win32.RegistryView]::Registry32 }
    $hive = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
    $key = $null; $overrideKey = $null
    try {
        $key = $hive.OpenSubKey("SYSTEM\CurrentControlSet\Services\$Service")
        if ($null -eq $key) { return [PSCustomObject]@{ Service = $Service; Exists = $false } }
        $image = Get-VirtioRegistryValue $key 'ImagePath'
        $driverPath = ''; $driverIssue = ''
        try { $driverPath = Resolve-VirtioDriverPath -ImagePath ([string]$image.Value) -Service $Service } catch { $driverIssue = $_.Exception.Message }
        $overrideKey = $key.OpenSubKey('StartOverride')
        $overrides = @()
        if ($null -ne $overrideKey) {
            $overrides = @($overrideKey.GetValueNames() | Sort-Object | ForEach-Object { Get-VirtioRegistryValue $overrideKey $_ })
        }
        [PSCustomObject]@{
            Service = $Service; Exists = $true
            Start = (Get-VirtioRegistryValue $key 'Start')
            Type = (Get-VirtioRegistryValue $key 'Type')
            Group = [string]$key.GetValue('Group')
            ImagePath = [string]$image.Value; DriverPath = $driverPath; DriverIssue = $driverIssue
            DriverFilePresent = [bool]($driverPath -and (Test-Path -LiteralPath $driverPath -PathType Leaf))
            Overrides = $overrides
        }
    } finally {
        if ($null -ne $overrideKey) { $overrideKey.Dispose() }
        if ($null -ne $key) { $key.Dispose() }
        $hive.Dispose()
    }
}

function Get-VirtioBootPlan {
    param([Parameter(Mandatory = $true)]$State)
    if ($State.Service -notin @('vioscsi', 'viostor')) { throw 'Only VirtIO storage services can be prepared. NetKVM is not a boot-storage driver.' }
    $issues = @(); $changes = @()
    if (-not $State.Exists) {
        $issues += 'The driver service is missing. Staging an INF alone is insufficient; install/register the storage driver before preparing it. No service key will be created.'
    } else {
        if ($null -eq $State.Type -or $State.Type.Kind -ne 'DWord' -or $State.Type.Value -ne 1 -or $State.Group -ne 'SCSI miniport') {
            $issues += 'The service is not a registered SCSI miniport kernel driver. Repair its installation first.'
        }
        if ($State.DriverIssue) { $issues += $State.DriverIssue }
        if (-not $State.DriverFilePresent) { $issues += 'The registered driver binary is missing. Repair its installation first.' }
        if ($null -eq $State.Start -or $State.Start.Kind -ne 'DWord' -or $State.Start.Value -notin @(0, 1, 2, 3, 4)) {
            $issues += 'Start must be an existing REG_DWORD with a supported startup value.'
        } elseif ($State.Start.Value -ne 0) {
            $changes += [PSCustomObject]@{ SubKey = ''; Name = 'Start'; Before = [int]$State.Start.Value; After = 0 }
        }
        foreach ($entry in $State.Overrides) {
            if ($entry.Kind -ne 'DWord' -or $entry.Value -notin @(0, 1, 2, 3, 4) -or $entry.Name -notmatch '^\d+$') {
                $issues += 'Unrecognized StartOverride values require manual review.'
            } elseif ($entry.Name -eq '0' -and $entry.Value -ne 0) {
                $changes += [PSCustomObject]@{ SubKey = 'StartOverride'; Name = '0'; Before = [int]$entry.Value; After = 0 }
            } elseif ($entry.Name -ne '0' -and $entry.Value -ne 0) {
                $issues += "StartOverride value '$($entry.Name)' needs manual review; only the existing value named '0' is adjusted."
            }
        }
    }
    [PSCustomObject]@{
        Service = $State.Service; CanPrepare = ($issues.Count -eq 0)
        AlreadyPrepared = ($issues.Count -eq 0 -and $changes.Count -eq 0)
        Issues = $issues; Changes = $changes; State = $State
    }
}

function Save-VirtioBootBackup {
    param($Plan, [string]$Directory)
    [void][IO.Directory]::CreateDirectory($Directory)
    $base = Join-Path $Directory ($Plan.Service + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
    $backup = [ordered]@{
        SchemaVersion = 1; ComputerName = $env:COMPUTERNAME; CreatedAt = (Get-Date).ToString('o')
        Service = $Plan.Service; State = $Plan.State; Changes = $Plan.Changes
    }
    [IO.File]::WriteAllText(($base + '.json'), ($backup | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($true)))
    $lines = @('Windows Registry Editor Version 5.00', '', '; Restore only on the original VM with a compatible boot controller.')
    foreach ($change in $Plan.Changes) {
        $suffix = if ($change.SubKey) { '\' + $change.SubKey } else { '' }
        $lines += "[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\$($Plan.Service)$suffix]"
        $lines += ('"{0}"=dword:{1:x8}' -f $change.Name, $change.Before)
        $lines += ''
    }
    [IO.File]::WriteAllText(($base + '.reg'), ($lines -join "`r`n"), [Text.Encoding]::Unicode)
    return $base
}

function Set-VirtioBootValue {
    param([ValidateSet('vioscsi', 'viostor')][string]$Service, $Change)
    if (-not (($Change.SubKey -eq '' -and $Change.Name -eq 'Start') -or
        ($Change.SubKey -eq 'StartOverride' -and $Change.Name -eq '0')) -or $Change.After -ne 0) {
        throw 'Unexpected boot preparation write.'
    }
    $view = if ([Environment]::Is64BitOperatingSystem) { [Microsoft.Win32.RegistryView]::Registry64 } else { [Microsoft.Win32.RegistryView]::Registry32 }
    $hive = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
    $key = $null
    try {
        $path = "SYSTEM\CurrentControlSet\Services\$Service"
        if ($Change.SubKey) { $path += '\' + $Change.SubKey }
        $key = $hive.OpenSubKey($path, $true)
        if ($null -eq $key) { throw 'The driver registry key disappeared. Check again before retrying.' }
        $current = Get-VirtioRegistryValue $key $Change.Name
        if ($null -eq $current -or $current.Kind -ne 'DWord' -or $current.Value -ne $Change.Before) {
            throw 'The driver startup value changed after inspection. Check again before retrying.'
        }
        $key.SetValue($Change.Name, 0, [Microsoft.Win32.RegistryValueKind]::DWord)
    } finally {
        if ($null -ne $key) { $key.Dispose() }
        $hive.Dispose()
    }
}

function Invoke-VirtioBootPreparation {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [ValidateSet('Check', 'Prepare')][string]$Mode = 'Check',
        [ValidateSet('vioscsi', 'viostor')][string]$Service = 'vioscsi',
        [string]$BackupDirectory
    )
    $plan = Get-VirtioBootPlan (Get-VirtioBootState -Service $Service)
    Write-Host "Storage service: $Service; Start: $($plan.State.Start.Value); driver: $($plan.State.DriverPath)"
    foreach ($change in $plan.Changes) { Write-Host "$Service\$($change.SubKey) [$($change.Name)]: $($change.Before) -> 0 (REG_DWORD)" }
    foreach ($issue in $plan.Issues) { Write-Host "BLOCKED: $issue" }
    $message = if (-not $plan.CanPrepare) { 'Boot preparation blocked: ' + ($plan.Issues -join ' ') }
        elseif ($plan.AlreadyPrepared) { "$Service already has the checked boot-start settings. This is not a boot test." }
        else { "$Service needs $($plan.Changes.Count) startup value change(s). No settings changed." }
    $backup = ''; $applied = $false
    if ($Mode -eq 'Prepare' -and -not $plan.CanPrepare) { throw $message }
    if ($Mode -eq 'Prepare' -and -not $plan.AlreadyPrepared -and
        $PSCmdlet.ShouldProcess($Service, 'Back up startup values and set Start / existing StartOverride 0 to Boot Start')) {
        if ([string]::IsNullOrWhiteSpace($BackupDirectory)) { throw 'A persistent backup directory is required.' }
        # Re-read before backup and mutation; installation may have changed the service.
        $fresh = Get-VirtioBootState -Service $Service
        if (($fresh | ConvertTo-Json -Depth 10 -Compress) -cne ($plan.State | ConvertTo-Json -Depth 10 -Compress)) {
            throw 'The driver state changed after inspection. Check again before retrying.'
        }
        $backup = Save-VirtioBootBackup -Plan $plan -Directory $BackupDirectory
        Write-Host "Startup backup: $backup.json; restore values: $backup.reg"
        try {
            foreach ($change in $plan.Changes) { Set-VirtioBootValue -Service $Service -Change $change }
            $verified = Get-VirtioBootPlan (Get-VirtioBootState -Service $Service)
            if (-not $verified.AlreadyPrepared) { throw 'Startup values did not pass verification after writing.' }
        } catch {
            throw "Boot preparation stopped; startup values may be partially changed. Backup: $backup.json and $backup.reg. $($_.Exception.Message)"
        }
        $applied = $true
        $message = "$Service boot-start settings prepared and verified. Backup: $backup.reg. Shut down for migration; check again if Windows boots on VMware first. This is not a boot test."
    }
    [PSCustomObject]@{
        Message = $message; CanPrepare = $plan.CanPrepare; Changed = $applied
        BackupPath = $backup; RebootRequired = $false
    }
}
