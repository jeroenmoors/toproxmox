#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ManifestPath,
    [Parameter(Mandatory = $true)][string]$CacheDirectory,
    [string]$InstallerPath
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'src/Drivers/VirtioDriverTools.ps1')
$manifest = Read-VirtioManifest -Path $ManifestPath
if ($InstallerPath) {
    $resolved = (Resolve-Path -LiteralPath $InstallerPath).ProviderPath
    Assert-VirtioInstaller -Path $resolved -Manifest $manifest
    return $resolved
}
$directory = Join-Path $CacheDirectory $manifest.Version
$destination = Join-Path $directory $manifest.FileName
if (Test-Path -LiteralPath $destination) {
    Assert-VirtioInstaller -Path $destination -Manifest $manifest
    return $destination
}
[void][IO.Directory]::CreateDirectory($directory)
$download = Join-Path $directory ([guid]::NewGuid().ToString('N') + '.download')
$previousProtocol = [Net.ServicePointManager]::SecurityProtocol
try {
    [Net.ServicePointManager]::SecurityProtocol = $previousProtocol -bor [Net.SecurityProtocolType]::Tls12
    Write-Host "Downloading VirtIO Guest Tools $($manifest.Version)..."
    Invoke-WebRequest -Uri $manifest.Url -OutFile $download -UseBasicParsing -TimeoutSec 300
    Assert-VirtioInstaller -Path $download -Manifest $manifest
    Move-Item -LiteralPath $download -Destination $destination -Force
} finally {
    [Net.ServicePointManager]::SecurityProtocol = $previousProtocol
    if (Test-Path -LiteralPath $download) { Remove-Item -LiteralPath $download -Force }
}
return $destination
