#Requires -Version 5.1
# Loading these functions never reads the registry or removes anything.
function Get-VmwareToolsState {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'VMware Tools removal requires Windows.' }
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $props = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
            if ([string]$props.DisplayName -eq 'VMware Tools') {
                $product = [string]$key.PSChildName
                return [PSCustomObject]@{
                    Installed = $true
                    DisplayName = [string]$props.DisplayName
                    DisplayVersion = [string]$props.DisplayVersion
                    ProductCode = $(if ($product -match '^\{[0-9A-Fa-f-]+\}$') { $product } else { '' })
                    UninstallString = [string]$props.UninstallString
                }
            }
        }
    }
    return [PSCustomObject]@{ Installed = $false }
}

function Invoke-VmwareToolsRemoval {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [ValidateSet('Check', 'Remove')][string]$Mode = 'Check',
        [string]$LogPath
    )
    $state = Get-VmwareToolsState
    if (-not $state.Installed) {
        Write-Host 'VMware Tools is not installed.'
        return [PSCustomObject]@{ Message = 'VMware Tools is not installed. Nothing to remove.'; Installed = $false; Changed = $false; RebootRequired = $false }
    }
    if ([string]::IsNullOrWhiteSpace($state.ProductCode)) {
        # Only a genuine MSI product code is removed; never run an arbitrary UninstallString.
        throw "VMware Tools $($state.DisplayVersion) was found but has no MSI product code. Remove it from Settings > Apps, then reboot."
    }
    Write-Host "VMware Tools detected: $($state.DisplayName) $($state.DisplayVersion); product $($state.ProductCode)"
    $message = "VMware Tools $($state.DisplayVersion) found. It will be removed with msiexec /x $($state.ProductCode) /qn /norestart. No changes made yet."
    $changed = $false; $rebootRequired = $false
    if ($Mode -eq 'Remove' -and
        $PSCmdlet.ShouldProcess("VMware Tools $($state.DisplayVersion)", 'Uninstall silently with msiexec')) {
        $msiexec = Join-Path $env:SystemRoot 'System32\msiexec.exe'
        $arguments = @('/x', $state.ProductCode, '/qn', '/norestart')
        if ($LogPath) { $arguments += @('/l*v', $LogPath) }
        $process = Start-Process -FilePath $msiexec -ArgumentList $arguments -Wait -PassThru
        switch ($process.ExitCode) {
            0 { $changed = $true; $message = 'VMware Tools removed. A reboot is recommended before using the guest.' }
            3010 { $changed = $true; $rebootRequired = $true; $message = 'VMware Tools removed. Restart Windows to complete the removal.' }
            1605 { $message = 'VMware Tools was already absent for the installer. Nothing to remove.' }
            1618 { throw 'Another installation is already in progress. Close it or reboot, then retry VMware Tools removal.' }
            default { throw "VMware Tools removal failed (msiexec exit $($process.ExitCode)). Review $LogPath, or remove it from Settings > Apps." }
        }
        if ($changed -and -not $rebootRequired) {
            $verify = Get-VmwareToolsState
            if ($verify.Installed) { throw 'VMware Tools still appears installed after removal. Reboot and retry, or remove it from Settings > Apps.' }
        }
    }
    return [PSCustomObject]@{ Message = $message; Installed = $true; Changed = $changed; RebootRequired = $rebootRequired }
}
