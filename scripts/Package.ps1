#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$entryPath = Join-Path $root 'src/ToProxmox.ps1'
$payload = [ordered]@{}
foreach ($name in @('Migrate-Network.ps1', 'Network-Migration-UI.ps1')) {
    $path = Join-Path $root "src/Network/$name"
    $tokens = $null; $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw "Syntax error in ${path}: $($parseErrors -join '; ')" }
    $payload[$name] = [Convert]::ToBase64String([IO.File]::ReadAllBytes($path))
}
$encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Compress)))
$template = [IO.File]::ReadAllText($entryPath)
$marker = '$embeddedPayload = '''' # PACKAGE_PAYLOAD'
if (($template.Split([string[]]@($marker), [StringSplitOptions]::None)).Count -ne 2) {
    throw 'The launcher must contain exactly one PACKAGE_PAYLOAD marker.'
}
$package = $template.Replace($marker, ('$embeddedPayload = ''' + $encoded + ''' # PACKAGE_PAYLOAD'))
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
