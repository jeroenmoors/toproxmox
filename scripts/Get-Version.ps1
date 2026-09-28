#Requires -Version 5.1
[CmdletBinding()]
param([string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
    throw 'Git is required to calculate the build version. Build from a Git checkout with complete history.'
}
function Invoke-VersionGit([string[]]$Arguments) {
    $output = & git -C $RepositoryRoot @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Cannot calculate the build version: $($output -join ' ')" }
    return ($output -join "`n").Trim()
}
$shallow = Invoke-VersionGit @('rev-parse', '--is-shallow-repository')
if ($shallow -eq 'true') {
    throw 'Versioning requires complete Git history. Run git fetch --unshallow before building.'
}
$commit = Invoke-VersionGit @('rev-parse', '--verify', 'HEAD')
$count = Invoke-VersionGit @('rev-list', '--count', 'HEAD')
if ($commit -notmatch '^[a-f0-9]{40,64}$' -or $count -notmatch '^\d+$') { throw 'Git returned invalid version metadata.' }
$dirty = -not [string]::IsNullOrWhiteSpace((Invoke-VersionGit @('status', '--porcelain', '--untracked-files=normal')))
# A new commit increases the reachable count; the hash identifies branches and amended commits.
$version = "0.1.$count"
$display = if ($dirty) { "$version-dev+g$($commit.Substring(0, 12))" } else { "$version+g$($commit.Substring(0, 12))" }
[PSCustomObject][ordered]@{
    Version = $version
    DisplayVersion = $display
    Commit = $commit
    Modified = $dirty
}
