#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$PackagePath)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$text = [IO.File]::ReadAllText($PackagePath, [Text.Encoding]::UTF8)
if (-not $text.StartsWith("@echo off`r`n")) { throw 'CMD header must use CRLF and have no BOM.' }
$match = [regex]::Match($text, '-EncodedCommand ([A-Za-z0-9+/=]+)\r\n')
if (-not $match.Success) { throw 'Missing encoded CMD bootstrap.' }
$bootstrap = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($match.Groups[1].Value))
if ($bootstrap -cne [IO.File]::ReadAllText((Join-Path $root 'src/Launch-Package.ps1'))) { throw 'Embedded bootstrap differs from source.' }
$marker = "`r`n# TOPROXMOX_POWERSHELL_PAYLOAD`r`n"
$header = $text.Substring(0, $text.IndexOf($marker, [StringComparison]::Ordinal))
if (-not $header.EndsWith('exit /b %TOPROXMOX_EXIT_CODE%')) { throw 'CMD must exit before reading the PowerShell payload.' }
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    Write-Host 'OK: CMD structure and embedded bootstrap. Windows process smoke tests skipped on this host.'
    return
}

# Exercise the actual CMD -> PowerShell bootstrap with a harmless substitute payload.
# No UI, elevation, drivers, or registry operations are started.
$temp = Join-Path ([IO.Path]::GetTempPath()) ('ToProxmox-cmd-' + [guid]::NewGuid().ToString('N'))
$process = $null
try {
    $specialDirectory = Join-Path $temp "folder with spaces & (brackets) ' !"
    [void][IO.Directory]::CreateDirectory($specialDirectory)
    $cmdPath = Join-Path $specialDirectory 'ToProxmox.cmd'
    $resultPath = Join-Path $temp 'result.json'
    foreach ($exitCode in @(0, 7)) {
        $payload = @'
$ErrorActionPreference = 'Stop'
@{ Path = $PSCommandPath; Text = 'Unicode: \u00e9'; Apartment = [string][Threading.Thread]::CurrentThread.ApartmentState } | ConvertTo-Json | Set-Content -LiteralPath $env:TOPROXMOX_SMOKE_RESULT -Encoding UTF8
exit __EXIT_CODE__
'@
        $payload = $payload.Replace('\u00e9', [string][char]0xE9).Replace('__EXIT_CODE__', [string]$exitCode)
        [IO.File]::WriteAllText($cmdPath, ($header + $marker + $payload), (New-Object Text.UTF8Encoding($false)))
        $start = New-Object Diagnostics.ProcessStartInfo
        $start.FileName = $env:ComSpec
        $start.Arguments = '/d /s /c ""' + $cmdPath + '" --no-pause"'
        $start.UseShellExecute = $false; $start.CreateNoWindow = $true
        $start.EnvironmentVariables['TOPROXMOX_SMOKE_RESULT'] = $resultPath
        $process = [Diagnostics.Process]::Start($start)
        if (-not $process.WaitForExit(30000)) { $process.Kill(); throw 'CMD smoke test timed out.' }
        if ($process.ExitCode -ne $exitCode) { throw "CMD lost the payload exit code: $($process.ExitCode) instead of $exitCode." }
        $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        if ($result.Text -cne ('Unicode: ' + [char]0xE9) -or $result.Apartment -ne 'STA') { throw 'Payload encoding or STA startup failed.' }
        if (Test-Path -LiteralPath (Split-Path -Parent $result.Path)) { throw 'Bootstrap did not clean up the extracted script.' }
        Remove-Item -LiteralPath $resultPath
        $process.Dispose(); $process = $null
    }
    Write-Host 'OK: Windows CMD startup, special-character paths, UTF-8, STA, exit codes and temporary-file cleanup.'
} finally {
    if ($null -ne $process) { $process.Dispose() }
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
