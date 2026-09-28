#Requires -Version 5.1
function Read-PackagedPowerShell([string]$Path) {
    $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    $marker = "`r`n# TOPROXMOX_POWERSHELL_PAYLOAD`r`n"
    $offset = $text.IndexOf($marker, [StringComparison]::Ordinal)
    if ($offset -lt 0) { throw 'Missing CMD package payload marker.' }
    return $text.Substring($offset + $marker.Length)
}
