#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$embeddedPayload = '' # PACKAGE_PAYLOAD
$embeddedDriver = '' # DRIVER_PAYLOAD

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'ToProxmox requires Windows with Desktop Experience and Windows PowerShell 5.1.'
}
$nativePs = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$sysnativePs = Join-Path $env:SystemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
if (Test-Path -LiteralPath $sysnativePs) { $nativePs = $sysnativePs }
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
# Relaunch the complete package before extracting, so its files outlive the UI.
if (-not $isAdmin -or $PSVersionTable.PSEdition -ne 'Desktop' -or
    [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA' -or
    ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess)) {
    $start = @{
        FilePath = $nativePs
        ArgumentList = ('-NoProfile -STA -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath)
        Wait = $true
        PassThru = $true
    }
    if (-not $isAdmin) { $start.Verb = 'RunAs' }
    try { $process = Start-Process @start } catch {
        throw "ToProxmox could not start with administrator privileges: $($_.Exception.Message)"
    }
    exit $process.ExitCode
}

$runtimeDirectory = $null
$exitCode = 0
try {
    if ($embeddedPayload) {
        $payload = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($embeddedPayload)) | ConvertFrom-Json
        $runtimeDirectory = Join-Path ([IO.Path]::GetTempPath()) ('ToProxmox-' + [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($runtimeDirectory)
        $allowedNames = @('Migrate-Network.ps1', 'Network-Migration-UI.ps1', 'Install-VirtioDrivers.ps1',
            'VirtioDriverTools.ps1', 'Prepare-VirtioBoot.ps1', 'VirtioBootTools.ps1', 'virtio-win.json', 'THIRD-PARTY.md', 'version.json')
        foreach ($property in $payload.PSObject.Properties) {
            $name = $property.Name
            if ($name -cnotin $allowedNames) { throw "Unexpected package entry: $name" }
            [IO.File]::WriteAllBytes((Join-Path $runtimeDirectory $name), [Convert]::FromBase64String($payload.$name))
        }
        if ($embeddedDriver) {
            [IO.File]::WriteAllBytes((Join-Path $runtimeDirectory 'virtio-win-guest-tools.exe'), [Convert]::FromBase64String($embeddedDriver))
        }
        $uiPath = Join-Path $runtimeDirectory 'Network-Migration-UI.ps1'
    } else {
        $uiPath = Join-Path $PSScriptRoot 'Network/Network-Migration-UI.ps1'
    }
    $process = Start-Process -FilePath $nativePs -ArgumentList ('-NoProfile -STA -ExecutionPolicy Bypass -File "{0}"' -f $uiPath) -Wait -PassThru
    $exitCode = $process.ExitCode
} finally {
    if ($runtimeDirectory -and (Test-Path -LiteralPath $runtimeDirectory)) {
        Remove-Item -LiteralPath $runtimeDirectory -Recurse -Force -ErrorAction Continue
    }
}
exit $exitCode
