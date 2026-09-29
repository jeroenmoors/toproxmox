#Requires -Version 5.1
# Shared by the runtime and tests. Loading this file never creates a device,
# compiles native code, or changes the system; the SetupAPI call only runs when
# Install-VirtioStorageDevice is invoked on Windows.

# VirtIO storage controllers are always PCI\VEN_1AF4 devices. The staged INF lists
# both the transitional and modern device IDs; we only need the plain two-part
# hardware IDs to create a root-enumerated node the driver package can bind to.
$script:VirtioStorageHardwareIdPattern = 'PCI\\VEN_1AF4&DEV_[0-9A-Fa-f]{4}'
# {4D36E97B-...} is the SCSIAdapter setup class shared by vioscsi and viostor.
$script:VirtioStorageClassGuid = '{4D36E97B-E325-11CE-BFC1-08002BE10318}'

function Get-VirtioStorageHardwareId {
    param([Parameter(Mandatory = $true)][string]$InfText)
    $ids = [regex]::Matches($InfText, $script:VirtioStorageHardwareIdPattern) |
        ForEach-Object { $_.Value.ToUpperInvariant() } | Select-Object -Unique
    return @($ids)
}

function Test-VirtioStorageInf {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('vioscsi', 'viostor')][string]$Service,
        [Parameter(Mandatory = $true)][string]$InfText
    )
    # An INF qualifies only if it is a SCSIAdapter-class package that installs the
    # exact storage binary for the requested service. This avoids matching NetKVM,
    # the balloon driver, or an unrelated SCSI adapter INF.
    $isScsiClass = $InfText -imatch ('ClassGUID\s*=\s*' + [regex]::Escape($script:VirtioStorageClassGuid)) -or
        $InfText -imatch '(?m)^\s*Class\s*=\s*SCSIAdapter\s*$'
    $hasBinary = $InfText -imatch [regex]::Escape("$Service.sys")
    return [bool]($isScsiClass -and $hasBinary)
}

function Get-VirtioStorageInfCandidate {
    param([Parameter(Mandatory = $true)][ValidateSet('vioscsi', 'viostor')][string]$Service)
    $candidates = @()
    if ([string]::IsNullOrEmpty($env:SystemRoot)) { return $candidates }
    # Published third-party drivers are renamed oemNN.inf, so match on content, not
    # file name. The DriverStore keeps the original name inside a decorated folder.
    $infDir = Join-Path $env:SystemRoot 'INF'
    if (Test-Path -LiteralPath $infDir) {
        $candidates += @(Get-ChildItem -LiteralPath $infDir -Filter 'oem*.inf' -File -ErrorAction SilentlyContinue |
            ForEach-Object { $_.FullName })
    }
    $repository = Join-Path $env:SystemRoot 'System32\DriverStore\FileRepository'
    if (Test-Path -LiteralPath $repository) {
        $candidates += @(Get-ChildItem -LiteralPath $repository -Directory -Filter "$Service.inf_*" -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName "$Service.inf" } | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    }
    return $candidates
}

function Find-VirtioStorageInf {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('vioscsi', 'viostor')][string]$Service,
        [string[]]$Candidate
    )
    if (-not $PSBoundParameters.ContainsKey('Candidate')) { $Candidate = Get-VirtioStorageInfCandidate -Service $Service }
    foreach ($path in $Candidate) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $text = [IO.File]::ReadAllText($path)
        if (-not (Test-VirtioStorageInf -Service $Service -InfText $text)) { continue }
        $ids = Get-VirtioStorageHardwareId -InfText $text
        if ($ids.Count -eq 0) { continue }
        return [PSCustomObject]@{ Service = $Service; InfPath = $path; HardwareIds = $ids }
    }
    return $null
}

$script:VirtioDeviceInstallerSource = @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class VirtioDeviceInstaller
{
    private const int DICD_GENERATE_ID = 0x00000001;
    private const int SPDRP_HARDWAREID = 0x00000001;
    private const int DIF_REGISTERDEVICE = 0x00000019;
    private const int DIF_REMOVE = 0x00000005;
    private const uint INSTALLFLAG_FORCE = 0x00000001;
    private const uint INSTALLFLAG_NONINTERACTIVE = 0x00000004;
    private static readonly IntPtr INVALID_HANDLE_VALUE = new IntPtr(-1);

    [StructLayout(LayoutKind.Sequential)]
    private struct SP_DEVINFO_DATA
    {
        public int cbSize;
        public Guid ClassGuid;
        public uint DevInst;
        public IntPtr Reserved;
    }

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool SetupDiGetINFClassW(string InfName, ref Guid ClassGuid, StringBuilder ClassName, uint ClassNameSize, out uint RequiredSize);

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern IntPtr SetupDiCreateDeviceInfoList(ref Guid ClassGuid, IntPtr hwndParent);

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool SetupDiCreateDeviceInfoW(IntPtr DeviceInfoSet, string DeviceName, ref Guid ClassGuid, string DeviceDescription, IntPtr hwndParent, int CreationFlags, ref SP_DEVINFO_DATA DeviceInfoData);

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiSetDeviceRegistryPropertyW(IntPtr DeviceInfoSet, ref SP_DEVINFO_DATA DeviceInfoData, int Property, byte[] PropertyBuffer, int PropertyBufferSize);

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiCallClassInstaller(int InstallFunction, IntPtr DeviceInfoSet, ref SP_DEVINFO_DATA DeviceInfoData);

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiDestroyDeviceInfoList(IntPtr DeviceInfoSet);

    [DllImport("newdev.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool UpdateDriverForPlugAndPlayDevicesW(IntPtr hwndParent, string HardwareId, string FullInfPath, uint InstallFlags, out bool bRebootRequired);

    private static byte[] BuildMultiSz(string[] values)
    {
        StringBuilder builder = new StringBuilder();
        foreach (string value in values)
        {
            builder.Append(value);
            builder.Append('\0');
        }
        builder.Append('\0');
        return Encoding.Unicode.GetBytes(builder.ToString());
    }

    // Mirrors the "Add legacy hardware" wizard / devcon install: create a
    // root-enumerated node for the hardware ID, then force the staged driver
    // package onto it. This registers the kernel service even though no VirtIO
    // controller is present yet on the source hypervisor.
    public static bool Install(string infPath, string[] hardwareIds)
    {
        if (string.IsNullOrEmpty(infPath)) { throw new ArgumentException("infPath is required."); }
        if (hardwareIds == null || hardwareIds.Length == 0) { throw new ArgumentException("At least one hardware ID is required."); }

        Guid classGuid = Guid.Empty;
        StringBuilder className = new StringBuilder(64);
        uint required;
        if (!SetupDiGetINFClassW(infPath, ref classGuid, className, (uint)className.Capacity, out required))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "SetupDiGetINFClass failed for " + infPath);
        }

        IntPtr deviceInfoSet = SetupDiCreateDeviceInfoList(ref classGuid, IntPtr.Zero);
        if (deviceInfoSet == INVALID_HANDLE_VALUE)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "SetupDiCreateDeviceInfoList failed");
        }
        try
        {
            SP_DEVINFO_DATA deviceInfoData = new SP_DEVINFO_DATA();
            deviceInfoData.cbSize = Marshal.SizeOf(typeof(SP_DEVINFO_DATA));
            if (!SetupDiCreateDeviceInfoW(deviceInfoSet, className.ToString(), ref classGuid, null, IntPtr.Zero, DICD_GENERATE_ID, ref deviceInfoData))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "SetupDiCreateDeviceInfo failed");
            }

            byte[] idBuffer = BuildMultiSz(hardwareIds);
            if (!SetupDiSetDeviceRegistryPropertyW(deviceInfoSet, ref deviceInfoData, SPDRP_HARDWAREID, idBuffer, idBuffer.Length))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "SetupDiSetDeviceRegistryProperty failed");
            }

            if (!SetupDiCallClassInstaller(DIF_REGISTERDEVICE, deviceInfoSet, ref deviceInfoData))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "SetupDiCallClassInstaller(REGISTERDEVICE) failed");
            }

            try
            {
                bool rebootRequired;
                if (!UpdateDriverForPlugAndPlayDevicesW(IntPtr.Zero, hardwareIds[0], infPath, INSTALLFLAG_FORCE | INSTALLFLAG_NONINTERACTIVE, out rebootRequired))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "UpdateDriverForPlugAndPlayDevices failed");
                }
                return rebootRequired;
            }
            catch
            {
                // Do not leave a bound-less phantom node behind on failure.
                SetupDiCallClassInstaller(DIF_REMOVE, deviceInfoSet, ref deviceInfoData);
                throw;
            }
        }
        finally
        {
            SetupDiDestroyDeviceInfoList(deviceInfoSet);
        }
    }
}
'@

function Install-VirtioStorageDevice {
    param(
        [Parameter(Mandatory = $true)][string]$InfPath,
        [Parameter(Mandatory = $true)][string[]]$HardwareId
    )
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Storage device registration requires Windows.' }
    if (-not (Test-Path -LiteralPath $InfPath -PathType Leaf)) { throw "The driver INF is missing: $InfPath" }
    if (-not ([Management.Automation.PSTypeName]'VirtioDeviceInstaller').Type) {
        Add-Type -TypeDefinition $script:VirtioDeviceInstallerSource -ErrorAction Stop
    }
    $rebootRequired = [VirtioDeviceInstaller]::Install($InfPath, $HardwareId)
    return [PSCustomObject]@{ RebootRequired = [bool]$rebootRequired }
}

function Invoke-VirtioStorageRegistration {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [ValidateSet('Check', 'Register')][string]$Mode = 'Check',
        [ValidateSet('vioscsi', 'viostor')][string]$Service = 'vioscsi'
    )
    $state = Get-VirtioBootState -Service $Service
    $issues = @(); $plan = $null; $alreadyRegistered = $false; $repair = $false
    if ($state.Exists -and $state.DriverFilePresent -and -not $state.DriverIssue) {
        $alreadyRegistered = $true
    } else {
        # A fresh registration, or a repair of an existing but incomplete service
        # (on VMware the wizard stages the package but never copies the binary or
        # completes the service, because the VirtIO controller is absent).
        $repair = [bool]$state.Exists
        $plan = Find-VirtioStorageInf -Service $Service
        if ($null -eq $plan) {
            if ($repair) {
                $issues += "A $Service service exists but its registered driver binary is missing or unexpected, and no staged $Service driver package was found to repair it. Reinstall the VirtIO drivers, then register the storage device."
            } else {
                $issues += "No staged $Service driver package was found. Install the VirtIO drivers first, then register the storage device."
            }
        }
    }
    $canRegister = ($issues.Count -eq 0 -and $null -ne $plan)
    if ($null -ne $plan) {
        $intent = if ($repair) { 'repairing the incomplete service' } else { 'creating a new device' }
        Write-Host "Storage service: $Service ($intent); driver package: $($plan.InfPath); hardware IDs: $($plan.HardwareIds -join ', ')"
    } else {
        Write-Host "Storage service: $Service; already registered: $alreadyRegistered"
    }
    foreach ($issue in $issues) { Write-Host "BLOCKED: $issue" }

    $message = if ($issues.Count -gt 0) { 'Storage registration blocked: ' + ($issues -join ' ') }
        elseif ($alreadyRegistered) { "$Service is already registered as a storage service. No device was created. You can continue with boot preparation." }
        elseif ($repair) { "$Service service exists but its driver binary is missing or unexpected; ToProxmox can repair it by force-installing the staged package from $($plan.InfPath). No changes made yet." }
        else { "$Service driver package found and ready to register from $($plan.InfPath). No device created yet." }

    $applied = $false; $rebootRequired = $false
    if ($Mode -eq 'Register' -and $issues.Count -gt 0) { throw $message }
    if ($Mode -eq 'Register' -and $canRegister -and
        $PSCmdlet.ShouldProcess($Service, 'Force-install the staged VirtIO driver to create or complete the storage service')) {
        # Re-check just before mutating; a concurrent install may have completed it.
        $fresh = Get-VirtioBootState -Service $Service
        if ($fresh.Exists -and $fresh.DriverFilePresent -and -not $fresh.DriverIssue) {
            $message = "$Service is already registered as a storage service. No device was created."
        } else {
            $result = Install-VirtioStorageDevice -InfPath $plan.InfPath -HardwareId $plan.HardwareIds
            $rebootRequired = [bool]$result.RebootRequired
            $verified = Get-VirtioBootState -Service $Service
            if (-not ($verified.Exists -and $verified.DriverFilePresent -and -not $verified.DriverIssue)) {
                throw "Registration ran but the $Service driver is still incomplete: the service or its binary is missing. Review Device Manager and the VirtIO driver installation."
            }
            $applied = $true
            $verb = if ($repair) { 'completed' } else { 'registered' }
            $message = "$Service storage device $verb and the service is ready. Continue with boot preparation, then shut down for migration." +
                $(if ($rebootRequired) { ' Restart Windows first.' } else { '' })
        }
    }
    [PSCustomObject]@{
        Message = $message; CanPrepare = $canRegister; Changed = $applied
        AlreadyRegistered = $alreadyRegistered; RebootRequired = $rebootRequired
    }
}
