#Requires -Version 5.1
# Dependency-free build tests. Never starts the UI or invokes network commands.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'PackageTestHelpers.ps1')
$temp = Join-Path ([IO.Path]::GetTempPath()) ('ToProxmox-test-' + [guid]::NewGuid().ToString('N'))
try {
    foreach ($directory in @('src', 'scripts', 'tests')) {
        foreach ($file in Get-ChildItem -LiteralPath (Join-Path $root $directory) -Filter '*.ps1' -Recurse) {
            $tokens = $null; $parseErrors = $null
            [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
            if ($parseErrors.Count -gt 0) { throw "Syntax error in $($file.FullName): $($parseErrors -join '; ')" }
        }
    }
    $package = & (Join-Path $root 'build.ps1') package -SkipDrivers -OutputDirectory (Join-Path $temp 'directory with spaces')
    if ($package.Extension -ne '.cmd') { throw 'The download must be a double-clickable CMD file.' }
    $tokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput((Read-PackagedPowerShell $package.FullName), [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw 'The package contains syntax errors.' }
    $assignment = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
        $node.Left.VariablePath.UserPath -eq 'embeddedPayload'
    }, $true)
    $driverAssignment = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
        $node.Left.VariablePath.UserPath -eq 'embeddedDriver'
    }, $true)
    if ($driverAssignment.Right.Expression.Value) { throw 'SkipDrivers still embedded an installer.' }
    $encoded = $assignment.Right.Expression.Value
    $payload = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded)) | ConvertFrom-Json
    if (@($payload.PSObject.Properties).Count -ne 9) { throw 'Unexpected package contents.' }
    $embeddedVersion = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload.'version.json')) | ConvertFrom-Json
    $expectedVersion = & (Join-Path $root 'scripts/Get-Version.ps1') -RepositoryRoot $root
    if ($embeddedVersion.DisplayVersion -cne $expectedVersion.DisplayVersion -or
        $embeddedVersion.Commit -cne $expectedVersion.Commit -or
        $embeddedVersion.Modified -ne $expectedVersion.Modified) {
        throw 'The package version does not match its Git revision and working-tree state.'
    }
    $expectedFiles = @{
        'Migrate-Network.ps1' = 'src/Network/Migrate-Network.ps1'
        'Network-Migration-UI.ps1' = 'src/Network/Network-Migration-UI.ps1'
        'Install-VirtioDrivers.ps1' = 'src/Drivers/Install-VirtioDrivers.ps1'
        'VirtioDriverTools.ps1' = 'src/Drivers/VirtioDriverTools.ps1'
        'Prepare-VirtioBoot.ps1' = 'src/Drivers/Prepare-VirtioBoot.ps1'
        'VirtioBootTools.ps1' = 'src/Drivers/VirtioBootTools.ps1'
        'virtio-win.json' = 'src/Drivers/virtio-win.json'
        'THIRD-PARTY.md' = 'docs/THIRD-PARTY.md'
    }
    foreach ($name in $expectedFiles.Keys) {
        $expected = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $root $expectedFiles[$name])))
        if ($payload.$name -cne $expected) { throw "Embedded file does not match: $name" }
    }
    $hash = (Get-FileHash -LiteralPath $package.FullName -Algorithm SHA256).Hash
    $second = & (Join-Path $root 'build.ps1') package -SkipDrivers -OutputDirectory (Join-Path $temp 'second')
    if ((Get-FileHash -LiteralPath $second.FullName -Algorithm SHA256).Hash -ne $hash) {
        throw 'Repeated builds produce different packages.'
    }
    if (@(Get-ChildItem -LiteralPath $package.DirectoryName -File).Count -ne 1) {
        throw 'The distribution must contain exactly one file.'
    }
    & (Join-Path $PSScriptRoot 'Test-CmdLauncher.ps1') -PackagePath $package.FullName
    Write-Host 'OK: syntax, embedded source files, path with spaces and reproducible single-file build.'
} finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
