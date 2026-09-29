#Requires -Version 5.1
# Fixture INFs and stubbed device/registry access. Never creates a device or
# compiles native code. Safe to run on any OS.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'src/Drivers/VirtioBootTools.ps1')
. (Join-Path $root 'src/Drivers/VirtioStorageDeviceTools.ps1')

function Assert-StorageFailure([scriptblock]$Action, [string]$Pattern) {
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_ }
    if ($null -eq $caught -or $caught.Exception.Message -notlike $Pattern) { throw "Expected '$Pattern', got: $caught" }
}
function New-StorageState([string]$Service = 'vioscsi', [bool]$Exists = $true, [bool]$FilePresent = $true, [string]$Issue = '') {
    [PSCustomObject]@{
        Service = $Service; Exists = $Exists
        DriverPath = "C:\Windows\System32\drivers\$Service.sys"; DriverIssue = $Issue; DriverFilePresent = $FilePresent
    }
}
$vioscsiInf = @'
[Version]
Signature="$WINDOWS NT$"
Class=SCSIAdapter
ClassGuid={4D36E97B-E325-11CE-BFC1-08002BE10318}

[Standard.NTamd64]
%vioscsi.DeviceDesc% = vioscsi_inst, PCI\VEN_1AF4&DEV_1004&SUBSYS_00081AF4&REV_00, PCI\VEN_1AF4&DEV_1004
%vioscsi.DeviceDesc% = vioscsi_inst, PCI\VEN_1AF4&DEV_1048&SUBSYS_11001AF4&REV_01, PCI\VEN_1AF4&DEV_1048

[vioscsi_inst.Services]
AddService = vioscsi, 2, vioscsi_Service_Inst

[vioscsi_Service_Inst]
ServiceBinary = %12%\vioscsi.sys
'@
$viostorInf = $vioscsiInf -replace 'vioscsi', 'viostor' -replace 'DEV_1004', 'DEV_1001' -replace 'DEV_1048', 'DEV_1042'
$netkvmInf = @'
[Version]
Signature="$WINDOWS NT$"
Class=Net
ClassGuid={4D36E972-E325-11CE-BFC1-08002BE10318}

[Standard.NTamd64]
%netkvm.DeviceDesc% = netkvm_inst, PCI\VEN_1AF4&DEV_1000
ServiceBinary = %12%\netkvm.sys
'@

$temp = Join-Path ([IO.Path]::GetTempPath()) ('ToProxmox-storage-test-' + [guid]::NewGuid().ToString('N'))
try {
    [void][IO.Directory]::CreateDirectory($temp)
    $vioscsiPath = Join-Path $temp 'oem10.inf'; [IO.File]::WriteAllText($vioscsiPath, $vioscsiInf)
    $viostorPath = Join-Path $temp 'oem11.inf'; [IO.File]::WriteAllText($viostorPath, $viostorInf)
    $netkvmPath = Join-Path $temp 'oem12.inf'; [IO.File]::WriteAllText($netkvmPath, $netkvmInf)

    # Hardware ID extraction keeps only the unique, uppercased two- and full-form IDs.
    $ids = Get-VirtioStorageHardwareId -InfText $vioscsiInf
    if ($ids -notcontains 'PCI\VEN_1AF4&DEV_1004' -or $ids -notcontains 'PCI\VEN_1AF4&DEV_1048') { throw 'Storage hardware IDs were not extracted.' }
    if ((Get-VirtioStorageHardwareId -InfText 'no ids here').Count -ne 0) { throw 'Non-VirtIO text produced hardware IDs.' }

    # INF matching is class- and binary-specific per service.
    if (-not (Test-VirtioStorageInf -Service vioscsi -InfText $vioscsiInf)) { throw 'A valid vioscsi INF was rejected.' }
    if (-not (Test-VirtioStorageInf -Service viostor -InfText $viostorInf)) { throw 'A valid viostor INF was rejected.' }
    if (Test-VirtioStorageInf -Service viostor -InfText $vioscsiInf) { throw 'A vioscsi INF matched viostor.' }
    if (Test-VirtioStorageInf -Service vioscsi -InfText $netkvmInf) { throw 'A NetKVM INF matched a storage service.' }

    # Discovery returns the correct candidate and skips unrelated INFs.
    $found = Find-VirtioStorageInf -Service vioscsi -Candidate @($netkvmPath, $viostorPath, $vioscsiPath)
    if ($null -eq $found -or $found.InfPath -ne $vioscsiPath -or $found.HardwareIds[0] -notlike 'PCI\VEN_1AF4&DEV_*') { throw 'vioscsi INF discovery failed.' }
    if ($null -ne (Find-VirtioStorageInf -Service vioscsi -Candidate @($netkvmPath))) { throw 'A non-storage INF was accepted.' }
    if ($null -ne (Find-VirtioStorageInf -Service vioscsi -Candidate @((Join-Path $temp 'missing.inf')))) { throw 'A missing candidate was accepted.' }

    # Orchestration with stubbed state and device installation; nothing native runs.
    $simulation = @{ State = (New-StorageState -Exists $false); FindResult = $found; Installs = 0; InstalledInf = ''; InstalledIds = @(); CreateOnInstall = $true; Reboot = $false }
    function Get-VirtioBootState { param($Service) return ($simulation.State | ConvertTo-Json -Depth 5 | ConvertFrom-Json) }
    function Find-VirtioStorageInf { param($Service, $Candidate) return $simulation.FindResult }
    function Install-VirtioStorageDevice {
        param($InfPath, $HardwareId)
        $simulation.Installs++
        $simulation.InstalledInf = $InfPath; $simulation.InstalledIds = $HardwareId
        if ($simulation.CreateOnInstall) { $simulation.State = New-StorageState -Exists $true }
        return [PSCustomObject]@{ RebootRequired = $simulation.Reboot }
    }

    # Missing service + staged INF: check plans, register creates and verifies.
    $check = Invoke-VirtioStorageRegistration -Mode Check -Service vioscsi
    if (-not $check.CanPrepare -or $check.Changed -or $simulation.Installs -ne 0) { throw 'Check should plan without installing.' }
    Invoke-VirtioStorageRegistration -Mode Register -Service vioscsi -WhatIf | Out-Null
    if ($simulation.Installs -ne 0) { throw 'WhatIf installed a device.' }
    $result = Invoke-VirtioStorageRegistration -Mode Register -Service vioscsi -Confirm:$false
    if (-not $result.Changed -or $simulation.Installs -ne 1) { throw 'Registration did not install exactly once.' }
    if ($simulation.InstalledInf -ne $vioscsiPath -or @($simulation.InstalledIds).Count -eq 0) { throw 'Registration passed the wrong INF or hardware IDs.' }

    # Already registered: no install, no change.
    $simulation.State = New-StorageState -Exists $true; $simulation.Installs = 0
    $result = Invoke-VirtioStorageRegistration -Mode Register -Service vioscsi -Confirm:$false
    if ($result.Changed -or -not $result.AlreadyRegistered -or $simulation.Installs -ne 0) { throw 'An already registered service was modified.' }

    # Existing but broken service: blocked, never duplicated.
    $simulation.State = New-StorageState -Exists $true -FilePresent $false; $simulation.Installs = 0
    if ((Invoke-VirtioStorageRegistration -Mode Check -Service vioscsi).CanPrepare) { throw 'A broken existing service must block registration.' }
    Assert-StorageFailure { Invoke-VirtioStorageRegistration -Mode Register -Service vioscsi -Confirm:$false } '*already exists*'
    if ($simulation.Installs -ne 0) { throw 'A broken service was duplicated.' }

    # Missing service + no staged INF: blocked, no install.
    $simulation.State = New-StorageState -Exists $false; $simulation.FindResult = $null; $simulation.Installs = 0
    if ((Invoke-VirtioStorageRegistration -Mode Check -Service vioscsi).CanPrepare) { throw 'A missing driver package must block registration.' }
    Assert-StorageFailure { Invoke-VirtioStorageRegistration -Mode Register -Service vioscsi -Confirm:$false } '*No staged*driver package*'
    if ($simulation.Installs -ne 0) { throw 'A missing package was installed.' }

    # Install ran but the service still does not exist: fail loudly.
    $simulation.FindResult = $found; $simulation.CreateOnInstall = $false; $simulation.State = New-StorageState -Exists $false; $simulation.Installs = 0
    Assert-StorageFailure { Invoke-VirtioStorageRegistration -Mode Register -Service vioscsi -Confirm:$false } '*service was not created*'
    if ($simulation.Installs -ne 1) { throw 'Verification failure should occur after one install attempt.' }

    Write-Host 'OK: hardware ID extraction, INF matching/discovery, registration planning, WhatIf, idempotence, blocked states and verification.'
} finally {
    Remove-Item Function:\Get-VirtioBootState -ErrorAction SilentlyContinue
    Remove-Item Function:\Find-VirtioStorageInf -ErrorAction SilentlyContinue
    Remove-Item Function:\Install-VirtioStorageDevice -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
