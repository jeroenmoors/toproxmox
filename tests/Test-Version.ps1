#Requires -Version 5.1
# All commits are in a disposable fixture repository, never the project repository.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$versionScript = Join-Path $root 'scripts/Get-Version.ps1'
$temp = Join-Path ([IO.Path]::GetTempPath()) ('ToProxmox-version-' + [guid]::NewGuid().ToString('N'))
$repository = Join-Path $temp 'repository with spaces'
function Invoke-TestGit([string[]]$Arguments) {
    & git -C $repository @Arguments | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Fixture Git command failed: $($Arguments -join ' ')" }
}
try {
    [void][IO.Directory]::CreateDirectory($repository)
    Invoke-TestGit @('init', '-q')
    Invoke-TestGit @('config', 'user.name', 'ToProxmox Tests')
    Invoke-TestGit @('config', 'user.email', 'tests@example.invalid')
    Invoke-TestGit @('config', 'commit.gpgsign', 'false')
    Invoke-TestGit @('config', 'core.autocrlf', 'false')
    $hooks = Join-Path $temp 'empty-hooks'
    [void][IO.Directory]::CreateDirectory($hooks)
    Invoke-TestGit @('config', 'core.hooksPath', $hooks)
    $file = Join-Path $repository 'sample.txt'
    [IO.File]::WriteAllText($file, 'first')
    Invoke-TestGit @('add', 'sample.txt')
    Invoke-TestGit @('commit', '-q', '-m', 'First fixture commit')
    $first = & $versionScript -RepositoryRoot $repository
    if ($first.Version -ne '0.1.1' -or $first.Modified -or $first.DisplayVersion -notmatch '^0\.1\.1\+g[a-f0-9]{12}$') {
        throw 'Incorrect clean commit version.'
    }
    [IO.File]::WriteAllText($file, 'second')
    $modified = & $versionScript -RepositoryRoot $repository
    if (-not $modified.Modified -or $modified.DisplayVersion -notmatch '-dev\+g') { throw 'Uncommitted changes were not marked.' }
    Invoke-TestGit @('add', 'sample.txt')
    Invoke-TestGit @('commit', '-q', '-m', 'Second fixture commit')
    $second = & $versionScript -RepositoryRoot $repository
    if ($second.Version -ne '0.1.2' -or $second.Modified -or $second.Commit -eq $first.Commit) { throw 'The version did not increase after a commit.' }
    $repeat = & $versionScript -RepositoryRoot $repository
    if (($repeat | ConvertTo-Json -Compress) -cne ($second | ConvertTo-Json -Compress)) { throw 'Version calculation is not deterministic.' }
    Invoke-TestGit @('commit', '-q', '--allow-empty', '-m', 'Empty fixture commit')
    if ((& $versionScript -RepositoryRoot $repository).Version -ne '0.1.3') { throw 'An empty commit did not increase the version.' }
    $untracked = Join-Path $repository 'untracked.txt'
    [IO.File]::WriteAllText($untracked, 'uncommitted file')
    if (-not (& $versionScript -RepositoryRoot $repository).Modified) { throw 'Untracked source changes were not marked.' }
    Remove-Item -LiteralPath $untracked
    $shallow = Join-Path $temp 'shallow'
    & git -c protocol.file.allow=always clone -q --depth 1 --no-local $repository $shallow
    if ($LASTEXITCODE -ne 0) { throw 'Failed to create shallow fixture.' }
    $caught = $null
    try { & $versionScript -RepositoryRoot $shallow | Out-Null } catch { $caught = $_ }
    if ($null -eq $caught -or $caught.Exception.Message -notlike '*complete Git history*') {
        throw 'Shallow history was not rejected.'
    }
    Write-Host 'OK: per-commit increments, clean/modified builds, deterministic metadata and shallow-clone rejection.'
} finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
