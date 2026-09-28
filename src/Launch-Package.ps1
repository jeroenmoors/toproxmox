#Requires -Version 5.1
# Embedded in the CMD header. Paths are passed as environment data, not code.
$ErrorActionPreference = 'Stop'
$directory = $null
$code = 1
try {
    $text = [IO.File]::ReadAllText($env:TOPROXMOX_PACKAGE, [Text.Encoding]::UTF8)
    $marker = "`r`n# TOPROXMOX_POWERSHELL_PAYLOAD`r`n"
    $offset = $text.IndexOf($marker, [StringComparison]::Ordinal)
    if ($offset -lt 0) { throw 'The ToProxmox package is incomplete. Download or build it again.' }
    $directory = Join-Path ([IO.Path]::GetTempPath()) ('ToProxmox-launch-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($directory)
    $scriptPath = Join-Path $directory 'ToProxmox.ps1'
    [IO.File]::WriteAllText($scriptPath, $text.Substring($offset + $marker.Length), (New-Object Text.UTF8Encoding($true)))
    # The existing launcher handles UAC and waits for the UI and its operations.
    & (Join-Path $PSHOME 'powershell.exe') -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File $scriptPath
    $code = $LASTEXITCODE
} catch {
    Write-Host ("ToProxmox could not start: " + $_.Exception.Message) -ForegroundColor Red
} finally {
    if ($directory -and (Test-Path -LiteralPath $directory)) {
        Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction Continue
    }
}
exit $code
