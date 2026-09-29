#Requires -Version 5.1
# Shared by the build and runtime; loading this file never installs anything.
function Read-VirtioManifest {
    param([Parameter(Mandatory = $true)][string]$Path)
    $manifest = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($manifest.FileName -cne 'virtio-win-guest-tools.exe' -or
        $manifest.Version -notmatch '^\d+\.\d+\.\d+-\d+$' -or
        $manifest.Sha256 -notmatch '^[a-fA-F0-9]{64}$' -or
        ([uri]$manifest.Url).Scheme -ne 'https') {
        throw 'Invalid VirtIO driver manifest.'
    }
    return $manifest
}

function Assert-VirtioInstaller {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)]$Manifest)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw 'The VirtIO installer is missing. Build the package with drivers first.'
    }
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Manifest.Sha256) {
        throw "VirtIO installer checksum mismatch: $Path. Obtain the exact version specified in virtio-win.json."
    }
}

function Invoke-VirtioSetup {
    param(
        [Parameter(Mandatory = $true)][string]$InstallerPath,
        [Parameter(Mandatory = $true)][string]$LogPath,
        [switch]$Unattended
    )
    # Interactive by default: the full upstream wizard handles component/license UI.
    # Unattended uses /passive: a visible progress bar with the default components
    # and license accepted without input. /norestart suppresses automatic restarts;
    # the caller reports reboot status.
    $mode = if ($Unattended) { '/passive ' } else { '' }
    $arguments = '/install {0}/norestart /log "{1}"' -f $mode, $LogPath
    $process = Start-Process -FilePath $InstallerPath -ArgumentList $arguments -Wait -PassThru
    switch ($process.ExitCode) {
        0 { return [PSCustomObject]@{ RebootRequired = $false; Message = 'VirtIO setup completed. Verify the installed devices before migration or network restore.' } }
        3010 { return [PSCustomObject]@{ RebootRequired = $true; Message = 'VirtIO setup completed. Restart Windows before migration or network restore.' } }
        1641 { return [PSCustomObject]@{ RebootRequired = $true; Message = 'VirtIO setup initiated a restart. Reopen ToProxmox after Windows restarts.' } }
        1602 { throw 'VirtIO setup was cancelled. Some components may already have changed; review the installer log.' }
        default { throw "VirtIO setup failed (exit code $($process.ExitCode)). Review $LogPath before retrying." }
    }
}
