#Requires -Version 5.1
# Uses fixture bytes and process/download stubs. Never runs an installer.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'PackageTestHelpers.ps1')
. (Join-Path $root 'src/Drivers/VirtioDriverTools.ps1')
function Assert-Failure([scriptblock]$Action, [string]$Pattern) {
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_ }
    if ($null -eq $caught -or $caught.Exception.Message -notlike $Pattern) {
        throw "Expected failure matching '$Pattern', got: $caught"
    }
}
$temp = Join-Path ([IO.Path]::GetTempPath()) ('ToProxmox-drivers-' + [guid]::NewGuid().ToString('N'))
try {
    [void][IO.Directory]::CreateDirectory($temp)
    $installer = Join-Path $temp 'fixture installer.exe'
    [IO.File]::WriteAllBytes($installer, [byte[]]@(77, 90, 0, 128, 255, 1, 2, 3))
    $manifestPath = Join-Path $temp 'virtio-win.json'
    $fixture = [ordered]@{
        Version = '0.0.0-0'; FileName = 'virtio-win-guest-tools.exe'
        Url = 'https://example.invalid/virtio-win-guest-tools.exe'
        Sha256 = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash
    }
    $fixture | ConvertTo-Json | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    $manifest = Read-VirtioManifest $manifestPath
    Assert-VirtioInstaller $installer $manifest
    Assert-Failure { Assert-VirtioInstaller (Join-Path $temp 'missing.exe') $manifest } '*missing*'

    $fixture.FileName = '../escape.exe'
    $fixture | ConvertTo-Json | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    Assert-Failure { Read-VirtioManifest $manifestPath } '*Invalid*'
    $fixture.FileName = 'virtio-win-guest-tools.exe'
    $fixture | ConvertTo-Json | Set-Content -LiteralPath $manifestPath -Encoding UTF8

    # Verify the bundled binary and its manifest survive packaging byte for byte.
    $package = & (Join-Path $root 'scripts/Package.ps1') -OutputDirectory (Join-Path $temp 'output') -DriverInstallerPath $installer -DriverManifestPath $manifestPath
    $tokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput((Read-PackagedPowerShell $package.FullName), [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw 'Driver-enabled package contains syntax errors.' }
    $assignment = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
        $node.Left.VariablePath.UserPath -eq 'embeddedPayload'
    }, $true)
    $payload = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($assignment.Right.Expression.Value)) | ConvertFrom-Json
    if (@($payload.PSObject.Properties).Count -ne 9) { throw 'Driver-enabled package has missing or extra entries.' }
    $driverAssignment = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
        $node.Left.VariablePath.UserPath -eq 'embeddedDriver'
    }, $true)
    $extracted = Join-Path $temp 'extracted.exe'
    [IO.File]::WriteAllBytes($extracted, [Convert]::FromBase64String($driverAssignment.Right.Expression.Value))
    Assert-VirtioInstaller $extracted $manifest
    if ($payload.'virtio-win.json' -cne [Convert]::ToBase64String([IO.File]::ReadAllBytes($manifestPath))) {
        throw 'Bundled driver manifest differs from the supplied manifest.'
    }
    $second = & (Join-Path $root 'scripts/Package.ps1') -OutputDirectory (Join-Path $temp 'second') -DriverInstallerPath $installer -DriverManifestPath $manifestPath
    if ((Get-FileHash $package.FullName).Hash -ne (Get-FileHash $second.FullName).Hash) { throw 'Driver packaging is not reproducible.' }
    Assert-Failure { & (Join-Path $root 'build.ps1') package -SkipDrivers -DriverInstallerPath $installer } '*cannot be combined*'

    # A download is checked before it enters the cache; cached files are rechecked.
    $downloadState = @{ Calls = 0 }
    function Invoke-WebRequest {
        param($Uri, $OutFile, [switch]$UseBasicParsing, $TimeoutSec)
        $downloadState.Calls++
        Copy-Item -LiteralPath $installer -Destination $OutFile
    }
    $resolveScript = Join-Path $root 'scripts/Get-VirtioInstaller.ps1'
    $cache = Join-Path $temp 'cache with spaces'
    $cached = & $resolveScript -ManifestPath $manifestPath -CacheDirectory $cache
    $again = & $resolveScript -ManifestPath $manifestPath -CacheDirectory $cache
    if ($downloadState.Calls -ne 1 -or $cached -ne $again) { throw 'Driver cache was not reused.' }
    [IO.File]::WriteAllText($cached, 'tampered cache')
    Assert-Failure { & $resolveScript -ManifestPath $manifestPath -CacheDirectory $cache } '*checksum mismatch*'
    [IO.File]::WriteAllText($installer, 'tampered download')
    Assert-Failure { & $resolveScript -ManifestPath $manifestPath -CacheDirectory (Join-Path $temp 'bad-download') } '*checksum mismatch*'
    if (@(Get-ChildItem -LiteralPath (Join-Path $temp 'bad-download') -File -Recurse).Count -ne 0) {
        throw 'A rejected download was left in the cache.'
    }
    Assert-Failure { & $resolveScript -ManifestPath $manifestPath -CacheDirectory $cache -InstallerPath $installer } '*checksum mismatch*'
    Assert-Failure { & (Join-Path $root 'scripts/Package.ps1') -OutputDirectory (Join-Path $temp 'bad-output') -DriverInstallerPath $installer -DriverManifestPath $manifestPath } '*checksum mismatch*'
    if (Test-Path -LiteralPath (Join-Path $temp 'bad-output/ToProxmox.cmd')) { throw 'A corrupt installer was packaged.' }

    function Start-Process {
        param($FilePath, $ArgumentList, [switch]$Wait, [switch]$PassThru)
        if ($FilePath -ne $installer -or -not $Wait -or -not $PassThru -or
            $ArgumentList -ne ('/install /norestart /log "{0}"' -f $log)) {
            throw 'Unexpected installer invocation or missing restart suppression.'
        }
        return [PSCustomObject]@{ ExitCode = $script:installerExitCode }
    }
    $log = Join-Path $temp 'log with spaces.log'
    $script:installerExitCode = 0
    if ((Invoke-VirtioSetup $installer $log).RebootRequired) { throw 'Successful setup incorrectly requests a reboot.' }
    foreach ($code in @(3010, 1641)) {
        $script:installerExitCode = $code
        if (-not (Invoke-VirtioSetup $installer $log).RebootRequired) { throw 'Setup reboot status was lost.' }
    }
    $script:installerExitCode = 1602
    Assert-Failure { Invoke-VirtioSetup $installer $log } '*cancelled*'
    $script:installerExitCode = 1603
    Assert-Failure { Invoke-VirtioSetup $installer $log } '*exit code 1603*'

    # The worker is itself a script stored inside a here-string in the UI.
    $uiAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'src/Network/Network-Migration-UI.ps1'), [ref]$tokens, [ref]$parseErrors)
    $worker = $uiAst.Find({
        param($node)
        $node -is [Management.Automation.Language.StringConstantExpressionAst] -and
        $node.Value.Contains("FromBase64String('__PAYLOAD__')")
    }, $true)
    if ($null -eq $worker) { throw 'UI worker script not found.' }
    [void][Management.Automation.Language.Parser]::ParseInput($worker.Value, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw 'UI worker contains syntax errors.' }
    Write-Host 'OK: driver bundle integrity, offline cache, corrupt downloads, reproducible embedding, installer arguments and exit codes.'
} finally {
    Remove-Item Function:\Start-Process -ErrorAction SilentlyContinue
    Remove-Item Function:\Invoke-WebRequest -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
