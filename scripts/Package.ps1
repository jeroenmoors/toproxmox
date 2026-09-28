#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [switch]$SkipDrivers,
    [string]$DriverInstallerPath,
    [string]$DriverManifestPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'src/Drivers/virtio-win.json')
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$entryPath = Join-Path $root 'src/ToProxmox.ps1'
if ($SkipDrivers -and $DriverInstallerPath) { throw 'SkipDrivers and DriverInstallerPath cannot be combined.' }
$files = [ordered]@{
    'Migrate-Network.ps1' = (Join-Path $root 'src/Network/Migrate-Network.ps1')
    'Network-Migration-UI.ps1' = (Join-Path $root 'src/Network/Network-Migration-UI.ps1')
    'Install-VirtioDrivers.ps1' = (Join-Path $root 'src/Drivers/Install-VirtioDrivers.ps1')
    'VirtioDriverTools.ps1' = (Join-Path $root 'src/Drivers/VirtioDriverTools.ps1')
    'Prepare-VirtioBoot.ps1' = (Join-Path $root 'src/Drivers/Prepare-VirtioBoot.ps1')
    'VirtioBootTools.ps1' = (Join-Path $root 'src/Drivers/VirtioBootTools.ps1')
    'virtio-win.json' = $DriverManifestPath
    'THIRD-PARTY.md' = (Join-Path $root 'docs/THIRD-PARTY.md')
}
$driverData = ''
if (-not $SkipDrivers) {
    $installer = & (Join-Path $PSScriptRoot 'Get-VirtioInstaller.ps1') -ManifestPath $DriverManifestPath -CacheDirectory (Join-Path $root '.cache/virtio-win') -InstallerPath $DriverInstallerPath
    $driverData = [Convert]::ToBase64String([IO.File]::ReadAllBytes($installer))
}
$payload = [ordered]@{}
foreach ($name in $files.Keys) {
    $path = $files[$name]
    if ($name.EndsWith('.ps1')) {
        $tokens = $null; $parseErrors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count -gt 0) { throw "Syntax error in ${path}: $($parseErrors -join '; ')" }
    }
    $payload[$name] = [Convert]::ToBase64String([IO.File]::ReadAllBytes($path))
}
$encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Compress)))
$template = [IO.File]::ReadAllText($entryPath)
$marker = '$embeddedPayload = '''' # PACKAGE_PAYLOAD'
if (($template.Split([string[]]@($marker), [StringSplitOptions]::None)).Count -ne 2) {
    throw 'The launcher must contain exactly one PACKAGE_PAYLOAD marker.'
}
$package = $template.Replace($marker, ('$embeddedPayload = ''' + $encoded + ''' # PACKAGE_PAYLOAD'))
# Keep the large binary out of JSON to avoid double Base64 expansion and JSON size limits.
$driverMarker = '$embeddedDriver = '''' # DRIVER_PAYLOAD'
if (($template.Split([string[]]@($driverMarker), [StringSplitOptions]::None)).Count -ne 2) {
    throw 'The launcher must contain exactly one DRIVER_PAYLOAD marker.'
}
$package = $package.Replace($driverMarker, ('$embeddedDriver = ''' + $driverData + ''' # DRIVER_PAYLOAD'))
$tokens = $null; $parseErrors = $null
[void][Management.Automation.Language.Parser]::ParseInput($package, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw "Syntax error in package: $($parseErrors -join '; ')" }
# UTF-8 BOM preserves non-ASCII text when Windows PowerShell 5.1 reads the file.
$outputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
[void][IO.Directory]::CreateDirectory($outputPath)
$destination = Join-Path $outputPath 'ToProxmox.ps1'
[IO.File]::WriteAllText($destination, $package, (New-Object Text.UTF8Encoding($true)))
Write-Host "Package created: $destination"
Get-Item -LiteralPath $destination
