#Requires -Version 5.1
[CmdletBinding()]
param(
    # Headless "Prepare host" for automation such as vCenter Invoke-VMScript.
    [switch]$PrepareHost,
    [ValidateSet('vioscsi', 'viostor')][string]$Controller = 'vioscsi',
    [string]$ConfigPath,
    [switch]$NoPause
)
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
# Forward the command-line selection across the elevation/bitness relaunch.
$selfArgs = ''
if ($PrepareHost) { $selfArgs += ' -PrepareHost' }
if ($Controller) { $selfArgs += ' -Controller ' + $Controller }
if ($ConfigPath) { $selfArgs += ' -ConfigPath "' + $ConfigPath + '"' }
if ($NoPause) { $selfArgs += ' -NoPause' }
# Headless preparation must never show a UAC prompt: fail clearly instead.
if ($PrepareHost -and -not $isAdmin) {
    throw 'Prepare host requires administrator rights. Run it elevated, for example as SYSTEM through vCenter Invoke-VMScript.'
}
# The UI needs an STA apartment; headless preparation does not.
$needsSta = -not $PrepareHost
$staRelaunch = $needsSta -and [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'
# Relaunch the complete package before extracting, so its files outlive the UI.
if (-not $isAdmin -or $PSVersionTable.PSEdition -ne 'Desktop' -or $staRelaunch -or
    ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess)) {
    $staSwitch = if ($needsSta) { ' -STA' } else { '' }
    $start = @{
        FilePath = $nativePs
        ArgumentList = ('-NoProfile{0} -ExecutionPolicy Bypass -File "{1}"{2}' -f $staSwitch, $PSCommandPath, $selfArgs)
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
        $allowedNames = @('Migrate-Network.ps1', 'Network-Migration-UI.ps1', 'Prepare-Host.ps1', 'Remove-VmwareTools.ps1',
            'VmwareToolsTools.ps1', 'Install-VirtioDrivers.ps1',
            'VirtioDriverTools.ps1', 'Prepare-VirtioBoot.ps1', 'VirtioBootTools.ps1', 'Register-VirtioStorage.ps1',
            'VirtioStorageDeviceTools.ps1', 'virtio-win.json', 'THIRD-PARTY.md', 'version.json')
        foreach ($property in $payload.PSObject.Properties) {
            $name = $property.Name
            if ($name -cnotin $allowedNames) { throw "Unexpected package entry: $name" }
            [IO.File]::WriteAllBytes((Join-Path $runtimeDirectory $name), [Convert]::FromBase64String($payload.$name))
        }
        if ($embeddedDriver) {
            [IO.File]::WriteAllBytes((Join-Path $runtimeDirectory 'virtio-win-guest-tools.exe'), [Convert]::FromBase64String($embeddedDriver))
        }
        $launchBase = $runtimeDirectory
    } else {
        $launchBase = Join-Path $PSScriptRoot 'Network'
    }
    if ($PrepareHost) {
        $orchestratorPath = Join-Path $launchBase 'Prepare-Host.ps1'
        $argList = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Controller {1}' -f $orchestratorPath, $Controller
        if ($ConfigPath) { $argList += ' -ConfigPath "{0}"' -f $ConfigPath }
        # -NoNewWindow keeps stdout attached so automation (e.g. vCenter) captures it.
        $process = Start-Process -FilePath $nativePs -ArgumentList $argList -Wait -PassThru -NoNewWindow
    } else {
        $uiPath = Join-Path $launchBase 'Network-Migration-UI.ps1'
        $process = Start-Process -FilePath $nativePs -ArgumentList ('-NoProfile -STA -ExecutionPolicy Bypass -File "{0}"' -f $uiPath) -Wait -PassThru
    }
    $exitCode = $process.ExitCode
} finally {
    if ($runtimeDirectory -and (Test-Path -LiteralPath $runtimeDirectory)) {
        Remove-Item -LiteralPath $runtimeDirectory -Recurse -Force -ErrorAction Continue
    }
}
exit $exitCode
