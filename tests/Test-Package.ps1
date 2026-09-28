#Requires -Version 5.1
# Dependency-free build tests. Never starts the UI or invokes network commands.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$temp = Join-Path ([IO.Path]::GetTempPath()) ('ToProxmox-test-' + [guid]::NewGuid().ToString('N'))
try {
    foreach ($directory in @('src', 'scripts', 'tests')) {
        foreach ($file in Get-ChildItem -LiteralPath (Join-Path $root $directory) -Filter '*.ps1' -Recurse) {
            $tokens = $null; $parseErrors = $null
            [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
            if ($parseErrors.Count -gt 0) { throw "Syntax error in $($file.FullName): $($parseErrors -join '; ')" }
        }
    }
    $package = & (Join-Path $root 'build.ps1') package -OutputDirectory (Join-Path $temp 'directory with spaces')
    $tokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($package.FullName, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw 'The package contains syntax errors.' }
    $assignment = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
        $node.Left.VariablePath.UserPath -eq 'embeddedPayload'
    }, $true)
    $encoded = $assignment.Right.Expression.Value
    $payload = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded)) | ConvertFrom-Json
    if (@($payload.PSObject.Properties).Count -ne 2) { throw 'Unexpected package contents.' }
    foreach ($name in @('Migrate-Network.ps1', 'Network-Migration-UI.ps1')) {
        $expected = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $root "src/Network/$name")))
        if ($payload.$name -cne $expected) { throw "Embedded file does not match: $name" }
    }
    $hash = (Get-FileHash -LiteralPath $package.FullName -Algorithm SHA256).Hash
    $second = & (Join-Path $root 'build.ps1') package -OutputDirectory (Join-Path $temp 'second')
    if ((Get-FileHash -LiteralPath $second.FullName -Algorithm SHA256).Hash -ne $hash) {
        throw 'Repeated builds produce different packages.'
    }
    if (@(Get-ChildItem -LiteralPath $package.DirectoryName -File).Count -ne 1) {
        throw 'The distribution must contain exactly one file.'
    }
    Write-Host 'OK: syntax, embedded source files, path with spaces and reproducible single-file build.'
} finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
