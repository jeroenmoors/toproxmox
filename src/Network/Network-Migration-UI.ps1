#Requires -Version 5.1
<#
Windows Forms frontend for the bundled Migrate-Network.ps1.
Run with ToProxmox.cmd (or src/ToProxmox.ps1), inside the Windows VM (Desktop Experience).
Operations run in a separate elevated Windows PowerShell process. The UI polls
its transcript and structured result, without blocking the WinForms event loop.
No network changes occur merely by opening the UI or inspecting an export.
#>
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$nativePs = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe')) {
    $nativePs = Join-Path $env:SystemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
}
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    try {
        $launchArgs = '-NoProfile -STA -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath
        Start-Process -FilePath $nativePs -ArgumentList $launchArgs -Verb RunAs | Out-Null
    } catch {
        [System.Windows.Forms.MessageBox]::Show('Administrator privileges are required. No changes were made.', 'Network migration') | Out-Null
        exit 1
    }
    exit 0
}
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    [System.Windows.Forms.MessageBox]::Show('Start using ToProxmox.cmd, or run src/ToProxmox.ps1 in Windows PowerShell STA mode.', 'Network migration') | Out-Null
    exit 1
}
$enginePath = Join-Path $PSScriptRoot 'Migrate-Network.ps1'
if (-not (Test-Path -LiteralPath $enginePath -PathType Leaf)) {
    [System.Windows.Forms.MessageBox]::Show('Migrate-Network.ps1 is missing. Build or download ToProxmox again.', 'Network migration') | Out-Null
    exit 1
}
# VMware Tools detection shares its logic with the removal engine (a sibling file).
$vmwareEnginePath = Join-Path $PSScriptRoot 'Remove-VmwareTools.ps1'
$vmwareToolsLib = Join-Path $PSScriptRoot 'VmwareToolsTools.ps1'
if (Test-Path -LiteralPath $vmwareToolsLib -PathType Leaf) { . $vmwareToolsLib }

# Packaged files are siblings; source checkouts keep drivers in src/Drivers.
$driverRoot = $PSScriptRoot
if (-not (Test-Path -LiteralPath (Join-Path $driverRoot 'Install-VirtioDrivers.ps1'))) {
    $driverRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'Drivers'
}
$driverManifestPath = Join-Path $driverRoot 'virtio-win.json'
$driverManifest = Get-Content -LiteralPath $driverManifestPath -Raw | ConvertFrom-Json
$driverInstallerPath = Join-Path $PSScriptRoot 'virtio-win-guest-tools.exe'
if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'Install-VirtioDrivers.ps1'))) {
    $repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $driverInstallerPath = Join-Path $repositoryRoot ('.cache/virtio-win/' + $driverManifest.Version + '/virtio-win-guest-tools.exe')
}
$versionPath = Join-Path $PSScriptRoot 'version.json'
if (Test-Path -LiteralPath $versionPath -PathType Leaf) {
    $appVersion = (Get-Content -LiteralPath $versionPath -Raw | ConvertFrom-Json).DisplayVersion
} else {
    # Source checkouts resolve the current revision; packages never need Git.
    try {
        $versionRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $appVersion = (& (Join-Path $versionRoot 'scripts/Get-Version.ps1') -RepositoryRoot $versionRoot).DisplayVersion
    } catch {
        $appVersion = 'development (version unavailable)'
    }
}
$script:Ui = @{
    Busy = $false; Job = $null; ExportPath = ''; ExportHash = ''; Saved = $null
    PreviewKey = ''; LogDirectory = ''; Engine = $enginePath; PowerShell = $nativePs
    DriverEngine = (Join-Path $driverRoot 'Install-VirtioDrivers.ps1')
    DriverInstaller = $driverInstallerPath; DriverManifest = $driverManifestPath
    RebootRequired = $false; Batch = $false; Queue = $null; Exiting = $false
    BootEngine = (Join-Path $driverRoot 'Prepare-VirtioBoot.ps1')
    StorageEngine = (Join-Path $driverRoot 'Register-VirtioStorage.ps1')
    VmwareEngine = $vmwareEnginePath; VmwareInstalled = $false
}

function New-Label([string]$Text) {
    $c = New-Object System.Windows.Forms.Label
    $c.Text = $Text; $c.AutoSize = $true; $c.Dock = 'Fill'
    $c.Margin = New-Object System.Windows.Forms.Padding(4, 6, 4, 6)
    return $c
}
function New-Button([string]$Text, [int]$Width = 180) {
    $c = New-Object System.Windows.Forms.Button
    $c.Text = $Text; $c.AutoSize = $true
    $c.MinimumSize = New-Object System.Drawing.Size($Width, 34)
    $c.Margin = New-Object System.Windows.Forms.Padding(4)
    return $c
}
function New-ReadOnlyText {
    $c = New-Object System.Windows.Forms.TextBox
    $c.Multiline = $true; $c.ReadOnly = $true; $c.ScrollBars = 'Vertical'; $c.Dock = 'Fill'
    return $c
}
function Show-UiError([string]$Message) {
    $statusLabel.Text = 'Stopped: ' + $Message
    [System.Windows.Forms.MessageBox]::Show($form, $Message, 'Network migration', 'OK', 'Error') | Out-Null
}
function Invalidate-Preview {
    $script:Ui.PreviewKey = ''
    $restoreButton.Enabled = $false
}
function Update-Buttons {
    $busy = $script:Ui.Busy
    $tabs.Enabled = -not $busy
    $closeButton.Enabled = -not $busy
    $saveLogButton.Enabled = -not $busy -and $logText.TextLength -gt 0
    $reboot = $script:Ui.RebootRequired
    $installerPresent = Test-Path -LiteralPath $script:Ui.DriverInstaller -PathType Leaf
    # Pre-migration: per-task buttons and the combined "Prepare host" button.
    $installDriversButton.Enabled = -not $busy -and -not $reboot -and $installerPresent
    $registerStorageButton.Enabled = -not $busy -and -not $reboot
    $prepareBootButton.Enabled = -not $busy -and -not $reboot
    $saveConfigButton.Enabled = -not $busy
    $anyTask = $cbInstall.Checked -or $cbRegister.Checked -or $cbBoot.Checked -or $cbSave.Checked
    $prepareHostButton.Enabled = -not $busy -and -not $reboot -and $anyTask
    # Post-migration: restore controls.
    $previewButton.Enabled = -not $busy -and $null -ne $sourceCombo.SelectedItem -and $null -ne $targetCombo.SelectedItem
    $restoreButton.Enabled = $previewButton.Enabled -and -not [string]::IsNullOrWhiteSpace($script:Ui.PreviewKey)
    $removeVmwareButton.Enabled = -not $busy -and $script:Ui.VmwareInstalled
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "ToProxmox v$appVersion | Windows migration"
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size(980, 700)
$form.MinimumSize = New-Object System.Drawing.Size(860, 620)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$form.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
$form.AutoScaleMode = 'Dpi'
$form.BackColor = [Drawing.Color]::WhiteSmoke

$root = New-Object System.Windows.Forms.TableLayoutPanel
$root.Dock = 'Fill'; $root.Padding = New-Object System.Windows.Forms.Padding(16)
$root.ColumnCount = 1; $root.RowCount = 6
$root.AutoScroll = $true
[void]$root.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
# The tab area fills the window; the operation log is shown in a separate popup.
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100)))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
$form.Controls.Add($root)
$title = New-Label 'Prepare Windows for Proxmox'
$title.Font = New-Object System.Drawing.Font('Segoe UI', 18, [Drawing.FontStyle]::Bold)
$root.Controls.Add($title, 0, 0)
$intro = New-Label "ToProxmox v$appVersion  |  Computer: $env:COMPUTERNAME  |  Administrator`r`nRestore using the Proxmox console. Network connectivity will be temporarily interrupted."
$root.Controls.Add($intro, 0, 1)

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = 'Fill'
$preTab = New-Object System.Windows.Forms.TabPage('Pre migration')
$postTab = New-Object System.Windows.Forms.TabPage('Post migration')
$tabs.TabPages.AddRange(@($preTab, $postTab))
$root.Controls.Add($tabs, 0, 2)

# --- Pre migration tab -------------------------------------------------------
$preLayout = New-Object System.Windows.Forms.TableLayoutPanel
$preLayout.Dock = 'Fill'; $preLayout.Padding = New-Object System.Windows.Forms.Padding(10)
$preLayout.ColumnCount = 2; $preLayout.RowCount = 8; $preLayout.AutoScroll = $true
[void]$preLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
[void]$preLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize')))
for ($row = 0; $row -lt 8; $row++) { [void]$preLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize'))) }
$preTab.Controls.Add($preLayout)

$preIntro = New-Label 'Prepare this VMware guest for Proxmox. All tasks are selected by default. "Prepare host" runs the selected tasks in order; each task also has its own button. Use the VM console: networking may be interrupted.'
$preLayout.Controls.Add($preIntro, 0, 0); $preLayout.SetColumnSpan($preIntro, 2)

$controllerPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$controllerPanel.AutoSize = $true; $controllerPanel.AutoSizeMode = 'GrowAndShrink'; $controllerPanel.Dock = 'Fill'; $controllerPanel.WrapContents = $false
$controllerLabel = New-Object System.Windows.Forms.Label
$controllerLabel.Text = 'Boot disk controller:'; $controllerLabel.AutoSize = $true
$controllerLabel.Margin = New-Object System.Windows.Forms.Padding(4, 10, 4, 6)
$controllerCombo = New-Object System.Windows.Forms.ComboBox
$controllerCombo.DropDownStyle = 'DropDownList'; $controllerCombo.DisplayMember = 'Label'; $controllerCombo.Width = 360
[void]$controllerCombo.Items.Add([PSCustomObject]@{ Label = 'VirtIO SCSI / VirtIO SCSI single (vioscsi)'; Service = 'vioscsi' })
[void]$controllerCombo.Items.Add([PSCustomObject]@{ Label = 'VirtIO Block (viostor)'; Service = 'viostor' })
$controllerCombo.SelectedIndex = 0
$controllerPanel.Controls.AddRange(@($controllerLabel, $controllerCombo))
$preLayout.Controls.Add($controllerPanel, 0, 1); $preLayout.SetColumnSpan($controllerPanel, 2)

$cbInstall = New-Object System.Windows.Forms.CheckBox
$cbInstall.Text = 'Install VirtIO drivers'; $cbInstall.AutoSize = $true; $cbInstall.Checked = $true; $cbInstall.Dock = 'Fill'
$cbInstall.Margin = New-Object System.Windows.Forms.Padding(4, 10, 4, 8)
$installDriversButton = New-Button 'Install now' 150
$preLayout.Controls.Add($cbInstall, 0, 2); $preLayout.Controls.Add($installDriversButton, 1, 2)

$cbRegister = New-Object System.Windows.Forms.CheckBox
$cbRegister.Text = 'Register storage driver (needed on VMware so the service exists)'; $cbRegister.AutoSize = $true; $cbRegister.Checked = $true; $cbRegister.Dock = 'Fill'
$cbRegister.Margin = New-Object System.Windows.Forms.Padding(4, 10, 4, 8)
$registerStorageButton = New-Button 'Register now' 150
$preLayout.Controls.Add($cbRegister, 0, 3); $preLayout.Controls.Add($registerStorageButton, 1, 3)

$cbBoot = New-Object System.Windows.Forms.CheckBox
$cbBoot.Text = 'Boot preparation (enable Boot Start for the selected controller)'; $cbBoot.AutoSize = $true; $cbBoot.Checked = $true; $cbBoot.Dock = 'Fill'
$cbBoot.Margin = New-Object System.Windows.Forms.Padding(4, 10, 4, 8)
$prepareBootButton = New-Button 'Prepare now' 150
$preLayout.Controls.Add($cbBoot, 0, 4); $preLayout.Controls.Add($prepareBootButton, 1, 4)

$cbSave = New-Object System.Windows.Forms.CheckBox
$cbSave.Text = 'Save network configuration to the Desktop'; $cbSave.AutoSize = $true; $cbSave.Checked = $true; $cbSave.Dock = 'Fill'
$cbSave.Margin = New-Object System.Windows.Forms.Padding(4, 10, 4, 8)
$saveConfigButton = New-Button 'Save now' 150
$preLayout.Controls.Add($cbSave, 0, 5); $preLayout.Controls.Add($saveConfigButton, 1, 5)

$prepareHostButton = New-Button 'Prepare host' 220
$prepareHostButton.Font = New-Object System.Drawing.Font('Segoe UI', 11, [Drawing.FontStyle]::Bold)
$preLayout.Controls.Add($prepareHostButton, 0, 6); $preLayout.SetColumnSpan($prepareHostButton, 2)

$driverStatusLabel = New-Label ''
if (Test-Path -LiteralPath $script:Ui.DriverInstaller -PathType Leaf) {
    $driverStatusLabel.Text = "VirtIO Guest Tools $($driverManifest.Version) available. No installer download is needed on this VM."
} else {
    $driverStatusLabel.Text = 'Driver installer not included; install is disabled. Build a package with drivers using: .\build.ps1 package'
    $cbInstall.Checked = $false; $cbInstall.Enabled = $false
}
$preLayout.Controls.Add($driverStatusLabel, 0, 7); $preLayout.SetColumnSpan($driverStatusLabel, 2)

# --- Post migration tab ------------------------------------------------------
$restoreLayout = New-Object System.Windows.Forms.TableLayoutPanel
$restoreLayout.Dock = 'Fill'; $restoreLayout.Padding = New-Object System.Windows.Forms.Padding(10)
$restoreLayout.ColumnCount = 3; $restoreLayout.RowCount = 9
[void]$restoreLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Absolute', 145)))
[void]$restoreLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
[void]$restoreLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Absolute', 200)))
 for ($row = 0; $row -lt 4; $row++) { [void]$restoreLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize'))) }
[void]$restoreLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100)))
[void]$restoreLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
[void]$restoreLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
[void]$restoreLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
[void]$restoreLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
$postTab.Controls.Add($restoreLayout)
$postIntro = New-Label 'Restore the saved network configuration after migration. An export found on the Desktop is loaded automatically; use "Load different config..." for another file. Select the old adapter and the matching new adapter, run a dry run, then restore.'
$restoreLayout.Controls.Add($postIntro, 0, 0); $restoreLayout.SetColumnSpan($postIntro, 3)
$restoreLayout.Controls.Add((New-Label 'Source file'), 0, 1)
$pathText = New-Object System.Windows.Forms.TextBox
$pathText.ReadOnly = $true; $pathText.Dock = 'Fill'
$restoreLayout.Controls.Add($pathText, 1, 1)
$openButton = New-Button 'Load different config...' 190
$restoreLayout.Controls.Add($openButton, 2, 1)
$restoreLayout.Controls.Add((New-Label 'Old adapter'), 0, 2)
$sourceCombo = New-Object System.Windows.Forms.ComboBox
$sourceCombo.Dock = 'Fill'; $sourceCombo.DropDownStyle = 'DropDownList'; $sourceCombo.DisplayMember = 'Label'
$restoreLayout.Controls.Add($sourceCombo, 1, 2); $restoreLayout.SetColumnSpan($sourceCombo, 2)
$restoreLayout.Controls.Add((New-Label 'New adapter'), 0, 3)
$targetCombo = New-Object System.Windows.Forms.ComboBox
$targetCombo.Dock = 'Fill'; $targetCombo.DropDownStyle = 'DropDownList'; $targetCombo.DisplayMember = 'Label'
$restoreLayout.Controls.Add($targetCombo, 1, 3); $restoreLayout.SetColumnSpan($targetCombo, 2)
$detailsText = New-ReadOnlyText
$restoreLayout.Controls.Add($detailsText, 0, 4); $restoreLayout.SetColumnSpan($detailsText, 3)
$removeCheck = New-Object System.Windows.Forms.CheckBox
$removeCheck.Text = 'Remove absent old adapter (only the exact adapter recorded in this export)'
$removeCheck.AutoSize = $true; $removeCheck.Dock = 'Fill'; $removeCheck.Checked = $false
$restoreLayout.Controls.Add($removeCheck, 0, 5); $restoreLayout.SetColumnSpan($removeCheck, 3)
$restoreActions = New-Object System.Windows.Forms.FlowLayoutPanel
$restoreActions.AutoSize = $true; $restoreActions.AutoSizeMode = 'GrowAndShrink'; $restoreActions.Dock = 'Fill'
$refreshButton = New-Button 'Refresh adapters' 170
$previewButton = New-Button '1. Dry run (no changes)' 240
$restoreButton = New-Button '2. Restore configuration' 240
$previewButton.Enabled = $false; $restoreButton.Enabled = $false
$restoreActions.Controls.AddRange(@($refreshButton, $previewButton, $restoreButton))
$restoreLayout.Controls.Add($restoreActions, 0, 6); $restoreLayout.SetColumnSpan($restoreActions, 3)
$vmwareStatusLabel = New-Label 'VMware Tools cleanup: after migration, remove VMware Tools; it crashes on Proxmox/KVM. A reboot is recommended afterwards.'
$restoreLayout.Controls.Add($vmwareStatusLabel, 0, 7); $restoreLayout.SetColumnSpan($vmwareStatusLabel, 3)
$vmwareActions = New-Object System.Windows.Forms.FlowLayoutPanel
$vmwareActions.AutoSize = $true; $vmwareActions.AutoSizeMode = 'GrowAndShrink'; $vmwareActions.Dock = 'Fill'
$removeVmwareButton = New-Button 'Remove VMware Tools...' 220
$removeVmwareButton.Enabled = $false
$vmwareActions.Controls.Add($removeVmwareButton)
$restoreLayout.Controls.Add($vmwareActions, 0, 8); $restoreLayout.SetColumnSpan($vmwareActions, 3)

# Current adapters are summarised through the target combo; keep this control
# for Refresh-Adapters output without occupying tab space.
$adapterText = New-ReadOnlyText
$adapterText.Font = New-Object System.Drawing.Font('Consolas', 10)

$root.Controls.Add((New-Label 'IPv4 + default routes. Additional static routes, manual IPv6 and teaming require separate handling.'), 0, 3)
$statusLabel = New-Label 'Ready. Viewing settings does not change anything.'
$root.Controls.Add($statusLabel, 0, 4)
$footer = New-Object System.Windows.Forms.FlowLayoutPanel
$footer.AutoSize = $true; $footer.AutoSizeMode = 'GrowAndShrink'; $footer.Dock = 'Fill'; $footer.FlowDirection = 'RightToLeft'
$closeButton = New-Button 'Close' 100
$saveLogButton = New-Button 'Save log...' 160
$saveLogButton.Enabled = $false
$showLogButton = New-Button 'Show log' 140
$footer.Controls.AddRange(@($closeButton, $saveLogButton, $showLogButton))
$root.Controls.Add($footer, 0, 5)

# The operation log lives in a separate popup so the tabs use the full window.
$logForm = New-Object System.Windows.Forms.Form
$logForm.Text = 'Operation log'
$logForm.StartPosition = 'CenterParent'
$logForm.ClientSize = New-Object System.Drawing.Size(840, 520)
$logForm.MinimumSize = New-Object System.Drawing.Size(500, 300)
$logForm.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$logForm.ShowInTaskbar = $false
$logText = New-Object System.Windows.Forms.TextBox
$logText.Multiline = $true; $logText.ReadOnly = $true; $logText.Dock = 'Fill'
$logText.Font = New-Object System.Drawing.Font('Consolas', 9)
$logText.WordWrap = $false; $logText.ScrollBars = 'Both'
$logForm.Controls.Add($logText)
# Closing the popup only hides it; it is disposed when the app exits.
$logForm.Add_FormClosing({
    param($logSender, $eventArgs)
    if (-not $script:Ui.Exiting) { $eventArgs.Cancel = $true; $logForm.Hide() }
})
function Show-LogWindow {
    if (-not $logForm.Visible) { $logForm.Show($form) }
    if ($logForm.WindowState -eq 'Minimized') { $logForm.WindowState = 'Normal' }
    $logForm.BringToFront()
}

function Refresh-Adapters {
    Invalidate-Preview
    $targetCombo.Items.Clear()
    $adapters = @(Get-NetAdapter -Physical | Sort-Object Name)
    $lines = foreach ($nic in $adapters) {
        $ip = @(Get-NetIPAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue)
        $addresses = ($ip | ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength)" }) -join ', '
        [void]$targetCombo.Items.Add([PSCustomObject]@{
            Label = "$($nic.Name) | $($nic.InterfaceDescription) | $($nic.MacAddress) | $($nic.Status)"
            Alias = [string]$nic.Name; Guid = [string]$nic.InterfaceGuid; Mac = [string]$nic.MacAddress
        })
        "$($nic.Name)  [$($nic.Status)]  MAC $($nic.MacAddress)`r`n  $($nic.InterfaceDescription)`r`n  IPv4: $addresses`r`n"
    }
    $adapterText.Text = $lines -join "`r`n"
    if ($adapters.Count -eq 0) { $adapterText.Text = 'No hardware network adapters found. Check the VirtIO driver.' }
    if ($targetCombo.Items.Count -eq 1) { $targetCombo.SelectedIndex = 0 }
    Update-Buttons
}
function Show-SourceDetails {
    Invalidate-Preview
    $detailsText.Clear()
    if ($null -ne $sourceCombo.SelectedItem) {
        $s = $sourceCombo.SelectedItem.Settings
        $ips = ($s.StaticIPv4 | ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength)" }) -join ', '
        $gateways = ($s.Gateways | ForEach-Object { "$($_.NextHop) (metric $($_.RouteMetric))" }) -join ', '
        $detailsText.Text = "Computer: $($script:Ui.Saved.ComputerName) | Export: $($script:Ui.Saved.ExportedAt)`r`nDHCP: $($s.Dhcp) | Static IPs: $ips`r`nGateways: $gateways`r`nDNS: $($s.DnsMode) - $($s.DnsServers -join ', ') | Suffix: $($s.DnsSuffix)"
        if (@($s.ExtraRoutes).Count -gt 0 -or @($s.ManualIPv6).Count -gt 0) {
            $detailsText.AppendText("`r`nWARNING: additional routes or manual IPv6 detected; restore will be blocked.")
        }
        if ([string]::IsNullOrWhiteSpace([string]$s.PnpInstanceId)) {
            $detailsText.AppendText("`r`nNo device ID in this export: automatic removal is unavailable.")
        }
    }
    Update-Buttons
}
function Load-Export([string]$FilePath) {
    Invalidate-Preview
    $sourceCombo.Items.Clear(); $script:Ui.Saved = $null
    $script:Ui.ExportPath = ''; $script:Ui.ExportHash = ''; $pathText.Clear()
    $data = Get-Content -LiteralPath $FilePath -Raw | ConvertFrom-Json
    if ($data.SchemaVersion -ne 1 -or @($data.Adapters).Count -eq 0) { throw 'No valid network export (schema 1) found.' }
    $script:Ui.Saved = $data
    $script:Ui.ExportPath = (Resolve-Path -LiteralPath $FilePath).ProviderPath
    $script:Ui.ExportHash = (Get-FileHash -LiteralPath $FilePath -Algorithm SHA256).Hash
    $pathText.Text = $script:Ui.ExportPath
    $removeCheck.Checked = $false
    foreach ($s in $data.Adapters) {
        [void]$sourceCombo.Items.Add([PSCustomObject]@{ Label = "$($s.Alias) | $($s.Description) | $($s.MacAddress)"; Settings = $s })
    }
    if ($sourceCombo.Items.Count -eq 1) { $sourceCombo.SelectedIndex = 0 }
    Show-SourceDetails
}
function Get-SelectionKey {
    if ($null -eq $sourceCombo.SelectedItem -or $null -eq $targetCombo.SelectedItem) { throw 'Select the old and new adapters.' }
    $currentHash = (Get-FileHash -LiteralPath $script:Ui.ExportPath -Algorithm SHA256).Hash
    if ($currentHash -ne $script:Ui.ExportHash) { throw 'The export file has changed. Open it again and perform a new dry run.' }
    $choice = $targetCombo.SelectedItem
    $live = @(Get-NetAdapter -Physical | Where-Object { $_.Name -eq $choice.Alias })
    if ($live.Count -ne 1 -or [string]$live[0].InterfaceGuid -ne $choice.Guid) {
        throw 'The target adapter has changed. Refresh the adapters and select it again.'
    }
    return (@($script:Ui.ExportPath, $currentHash, $sourceCombo.SelectedItem.Settings.Alias,
        $choice.Alias, $choice.Guid, [string]$removeCheck.Checked) | ConvertTo-Json -Compress)
}
function Get-DesktopExportPath {
    $desktop = [Environment]::GetFolderPath('Desktop')
    return (Join-Path $desktop "$env:COMPUTERNAME-network-$(Get-Date -Format yyyyMMdd-HHmmss).json")
}
function Find-DesktopExport {
    try {
        $desktop = [Environment]::GetFolderPath('Desktop')
        $files = @(Get-ChildItem -LiteralPath $desktop -Filter '*network*.json' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike '*before-restore*' } | Sort-Object LastWriteTime -Descending)
        foreach ($file in $files) {
            try { Load-Export $file.FullName; return $true } catch { }
        }
    } catch { }
    return $false
}
function Update-VmwareStatus {
    try {
        $state = Get-VmwareToolsState
        if ($state.Installed) {
            $script:Ui.VmwareInstalled = $true
            $vmwareStatusLabel.Text = "VMware Tools $($state.DisplayVersion) detected. Remove it after migration; it crashes on Proxmox/KVM. Reboot afterwards."
        } else {
            $script:Ui.VmwareInstalled = $false
            $vmwareStatusLabel.Text = 'VMware Tools not detected. Nothing to remove.'
        }
    } catch {
        $script:Ui.VmwareInstalled = $false
        $vmwareStatusLabel.Text = 'VMware Tools status unavailable: ' + $_.Exception.Message
    }
    Update-Buttons
}
function Invoke-NextQueued {
    if ($null -eq $script:Ui.Queue -or $script:Ui.Queue.Count -eq 0) {
        $script:Ui.Batch = $false; $script:Ui.Queue = $null; return
    }
    $step = $script:Ui.Queue.Dequeue()
    Start-Operation -Kind $step.Kind -Parameters $step.Parameters
}
function Start-HostPreparation {
    $queue = New-Object System.Collections.Generic.Queue[object]
    $service = $controllerCombo.SelectedItem.Service
    if ($cbInstall.Checked) { $queue.Enqueue(@{ Kind = 'Drivers'; Parameters = @{ InstallerPath = $script:Ui.DriverInstaller; ManifestPath = $script:Ui.DriverManifest; Unattended = $true } }) }
    if ($cbRegister.Checked) { $queue.Enqueue(@{ Kind = 'Storage register'; Parameters = @{ Mode = 'Register'; Service = $service } }) }
    if ($cbBoot.Checked) { $queue.Enqueue(@{ Kind = 'Boot prepare'; Parameters = @{ Mode = 'Prepare'; Service = $service } }) }
    if ($cbSave.Checked) { $queue.Enqueue(@{ Kind = 'Export'; Parameters = @{ Mode = 'Export'; Path = (Get-DesktopExportPath) } }) }
    if ($queue.Count -eq 0) { throw 'Select at least one task.' }
    $script:Ui.Batch = $true; $script:Ui.Queue = $queue
    Invoke-NextQueued
}
function Start-Operation([string]$Kind, [hashtable]$Parameters, [string]$SelectionKey = '') {
    if ($script:Ui.Busy) { return }
    $logRoot = Join-Path $env:ProgramData 'NetworkMigration\Logs'
    $opDir = Join-Path $logRoot ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $opDir -Force | Out-Null
    $transcriptPath = Join-Path $opDir 'operation.log'
    $resultPath = Join-Path $opDir 'result.json'
    if ($Kind -eq 'Boot prepare') { $Parameters['BackupDirectory'] = $opDir }
    if ($Kind -eq 'Drivers') { $Parameters['LogPath'] = Join-Path $opDir 'virtio-setup.log' }
    if ($Kind -eq 'Vmware remove') { $Parameters['LogPath'] = Join-Path $opDir 'vmware-tools-uninstall.log' }
    $payload = @{
        Engine = $(if ($Kind -eq 'Drivers') { $script:Ui.DriverEngine }
            elseif ($Kind -eq 'Boot prepare') { $script:Ui.BootEngine }
            elseif ($Kind -eq 'Storage register') { $script:Ui.StorageEngine }
            elseif ($Kind -in @('Vmware check', 'Vmware remove')) { $script:Ui.VmwareEngine }
            else { $script:Ui.Engine })
        Kind = $Kind; Parameters = $Parameters; Transcript = $transcriptPath
        Result = $resultPath; ExportHash = $(if ($Kind -in @('Dry run', 'Restore')) { $script:Ui.ExportHash } else { '' })
        TargetGuid = $(if ($Kind -in @('Dry run', 'Restore')) { $targetCombo.SelectedItem.Guid } else { '' })
    } | ConvertTo-Json -Depth 8 -Compress
    $payload64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
    # Only a Base64 data literal is inserted. Paths and adapter names are passed
    # as data/splatted parameters, never interpolated into executable PS code.
    $worker = @'
$ErrorActionPreference = 'Stop'
$payload = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__PAYLOAD__')) | ConvertFrom-Json
$result = @{ Success = $false; Message = ''; Finished = ''; RebootRequired = $false; CanPrepare = $false }
$transcribing = $false
try {
    Start-Transcript -Path $payload.Transcript -Force | Out-Null
    $transcribing = $true
    $parameters = @{}
    foreach ($property in $payload.Parameters.PSObject.Properties) { $parameters[$property.Name] = $property.Value }
    $parameters['Confirm'] = $false
    if ($payload.ExportHash) {
        if ((Get-FileHash -LiteralPath $parameters.Path -Algorithm SHA256).Hash -ne $payload.ExportHash) { throw 'Export changed before execution.' }
        $target = @(Get-NetAdapter -Physical | Where-Object { $_.Name -eq $parameters.TargetAlias })
        if ($target.Count -ne 1 -or [string]$target[0].InterfaceGuid -ne $payload.TargetGuid) { throw 'Target adapter changed before execution.' }
    }
    if ($payload.Kind -in @('Drivers', 'Boot prepare', 'Storage register', 'Vmware check', 'Vmware remove')) {
        $installation = & $payload.Engine @parameters
        $result.RebootRequired = [bool]$installation.RebootRequired
        $result.Message = $installation.Message
        $result.CanPrepare = [bool]$installation.CanPrepare
        Write-Host $result.Message
    } else {
        & $payload.Engine @parameters | Out-Host
        $result.Message = 'Operation completed.'
    }
    $result.Success = $true
} catch {
    $result.Message = $_.Exception.Message
    Write-Host ('ERROR: ' + $result.Message)
    Write-Host ($_ | Out-String)
} finally {
    $result.Finished = (Get-Date).ToString('o')
    if ($transcribing) { Stop-Transcript | Out-Null }
    $result | ConvertTo-Json | Set-Content -LiteralPath $payload.Result -Encoding UTF8
}
if (-not $result.Success) { exit 1 }
'@
    $worker = $worker.Replace('__PAYLOAD__', $payload64)
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($worker))
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $script:Ui.PowerShell
    $startInfo.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + $encoded
    $startInfo.UseShellExecute = $false; $startInfo.CreateNoWindow = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw 'Unable to start the worker process.' }
    $script:Ui.Job = @{ Process = $process; Kind = $Kind; Key = $SelectionKey; Parameters = $Parameters; Transcript = $transcriptPath; Result = $resultPath }
    $script:Ui.Busy = $true; $script:Ui.LogDirectory = $opDir
    Invalidate-Preview
    $logText.Text = "Operation: $Kind`r`nLog directory: $opDir`r`nPlease wait..."
    $statusLabel.Text = "$Kind in progress..."
    Show-LogWindow
    Update-Buttons
    $timer.Start()
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 400
$timer.Add_Tick({
    $job = $script:Ui.Job
    if ($null -eq $job) { $timer.Stop(); return }
    if (Test-Path -LiteralPath $job.Transcript) {
        $stream = $null; $reader = $null
        try {
            $stream = [IO.File]::Open($job.Transcript, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
            $reader = New-Object IO.StreamReader($stream)
            $text = $reader.ReadToEnd()
            if ($text -ne $logText.Text) {
                $logText.Text = $text; $logText.SelectionStart = $logText.TextLength; $logText.ScrollToCaret()
            }
        } catch { } finally { if ($null -ne $reader) { $reader.Dispose() } elseif ($null -ne $stream) { $stream.Dispose() } }
    }
    if (-not $job.Process.HasExited) { return }
    $timer.Stop()
    try {
        if (-not (Test-Path -LiteralPath $job.Result)) { throw "The worker process stopped without a result (exit code $($job.Process.ExitCode)). Check $($script:Ui.LogDirectory)." }
        $result = Get-Content -LiteralPath $job.Result -Raw | ConvertFrom-Json
        if (-not $result.Success -or $job.Process.ExitCode -ne 0) { throw $result.Message }
        if ($job.Kind -eq 'Drivers') {
            $script:Ui.RebootRequired = [bool]$result.RebootRequired
            $driverStatusLabel.Text = $result.Message
            Refresh-Adapters
            $statusLabel.Text = $result.Message
            if ($script:Ui.RebootRequired -and -not $script:Ui.Batch) {
                [System.Windows.Forms.MessageBox]::Show($form, $result.Message, 'Restart required', 'OK', 'Information') | Out-Null
            }
        } elseif ($job.Kind -eq 'Boot prepare') {
            $driverStatusLabel.Text = $result.Message
            $statusLabel.Text = $result.Message
        } elseif ($job.Kind -eq 'Storage register') {
            $script:Ui.RebootRequired = [bool]$result.RebootRequired
            $driverStatusLabel.Text = $result.Message
            $statusLabel.Text = $result.Message
            if ($script:Ui.RebootRequired -and -not $script:Ui.Batch) {
                [System.Windows.Forms.MessageBox]::Show($form, $result.Message, 'Restart required', 'OK', 'Information') | Out-Null
            }
        } elseif ($job.Kind -eq 'Dry run') {
            $script:Ui.PreviewKey = $job.Key
            $statusLabel.Text = 'Dry run succeeded. No settings were changed. You can now restore the configuration.'
        } elseif ($job.Kind -eq 'Vmware remove') {
            $statusLabel.Text = $result.Message
            Update-VmwareStatus
            if ([bool]$result.RebootRequired) {
                [System.Windows.Forms.MessageBox]::Show($form, $result.Message, 'Restart required', 'OK', 'Information') | Out-Null
            }
        } elseif ($job.Kind -eq 'Export') {
            Load-Export $job.Parameters.Path
            $driverStatusLabel.Text = 'Network configuration saved to: ' + $job.Parameters.Path
            $statusLabel.Text = 'Configuration saved to: ' + $job.Parameters.Path
        } else {
            Refresh-Adapters
            $statusLabel.Text = 'Restore completed. Check connectivity, DNS and the network profile; test again after a reboot.'
        }
    } catch {
        $script:Ui.Batch = $false; $script:Ui.Queue = $null
        Invalidate-Preview
        Show-UiError $_.Exception.Message
    } finally {
        $job.Process.Dispose(); $script:Ui.Job = $null; $script:Ui.Busy = $false
        Update-Buttons
        if ($script:Ui.Batch) {
            if ($script:Ui.RebootRequired) {
                $script:Ui.Batch = $false; $script:Ui.Queue = $null
                $statusLabel.Text = 'Restart required. Reboot Windows, then run Prepare host again for the remaining tasks.'
                [System.Windows.Forms.MessageBox]::Show($form, 'A restart is required before continuing. Reboot Windows, then run Prepare host again.', 'Restart required', 'OK', 'Information') | Out-Null
            } elseif ($null -ne $script:Ui.Queue -and $script:Ui.Queue.Count -gt 0) {
                Invoke-NextQueued
            } else {
                $script:Ui.Batch = $false; $script:Ui.Queue = $null
                $statusLabel.Text = 'Host preparation complete. Review the log, then shut down for migration.'
            }
        }
    }
})

$cbInstall.Add_CheckedChanged({ Update-Buttons })
$cbRegister.Add_CheckedChanged({ Update-Buttons })
$cbBoot.Add_CheckedChanged({ Update-Buttons })
$cbSave.Add_CheckedChanged({ Update-Buttons })
$registerStorageButton.Add_Click({
    try {
        $service = $controllerCombo.SelectedItem.Service
        $message = "Register a $service storage device? This mirrors the Add legacy hardware wizard: it force-installs the staged VirtIO driver to create its service, or completes an existing but incomplete one, so the migrated VM can boot. It does not change partitions or data. Keep a VM backup and console access. Continue?"
        if ([System.Windows.Forms.MessageBox]::Show($form, $message, 'Register storage device', 'YesNo', 'Warning', 'Button2') -ne 'Yes') { return }
        Start-Operation -Kind 'Storage register' -Parameters @{ Mode = 'Register'; Service = $service }
    } catch { Show-UiError $_.Exception.Message; Update-Buttons }
})
$prepareBootButton.Add_Click({
    try {
        $service = $controllerCombo.SelectedItem.Service
        $message = "Prepare $service for the Windows boot disk? The tool will back up the original values and set Start and any existing StartOverride value named 0 to Boot Start. Keep a VM backup and console access. After preparation, shut down for migration. This does not guarantee a successful boot on different hardware."
        if ([System.Windows.Forms.MessageBox]::Show($form, $message, 'Prepare storage boot driver', 'YesNo', 'Warning', 'Button2') -ne 'Yes') { return }
        Start-Operation -Kind 'Boot prepare' -Parameters @{ Mode = 'Prepare'; Service = $service }
    } catch { Show-UiError $_.Exception.Message; Update-Buttons }
})
$installDriversButton.Add_Click({
    try {
        $message = 'Open the VirtIO Guest Tools installer? The upstream wizard opens so you can choose components and accept the license. Save your network settings first and use the VM console. Networking may be interrupted. Automatic restarts are suppressed.'
        if ([System.Windows.Forms.MessageBox]::Show($form, $message, 'Install VirtIO drivers', 'YesNo', 'Warning', 'Button2') -ne 'Yes') { return }
        Start-Operation -Kind 'Drivers' -Parameters @{
            InstallerPath = $script:Ui.DriverInstaller; ManifestPath = $script:Ui.DriverManifest
        }
    } catch { Show-UiError $_.Exception.Message; Update-Buttons }
})
$saveConfigButton.Add_Click({
    try {
        $path = Get-DesktopExportPath
        Start-Operation -Kind 'Export' -Parameters @{ Mode = 'Export'; Path = $path }
    } catch { Show-UiError $_.Exception.Message; Update-Buttons }
})
$prepareHostButton.Add_Click({
    try {
        $tasks = @()
        if ($cbInstall.Checked) { $tasks += 'install VirtIO drivers (unattended)' }
        if ($cbRegister.Checked) { $tasks += 'register the storage driver' }
        if ($cbBoot.Checked) { $tasks += 'prepare boot settings' }
        if ($cbSave.Checked) { $tasks += 'save the network configuration to the Desktop' }
        if ($tasks.Count -eq 0) { throw 'Select at least one task.' }
        $message = "Prepare this host for Proxmox? The selected tasks run in order without further prompts:`r`n`r`n - " + ($tasks -join "`r`n - ") + "`r`n`r`nUse the VM console; networking may be interrupted. Keep a VM backup. If a restart is required the remaining tasks stop until you reboot."
        if ([System.Windows.Forms.MessageBox]::Show($form, $message, 'Prepare host', 'YesNo', 'Warning', 'Button2') -ne 'Yes') { return }
        Start-HostPreparation
    } catch { Show-UiError $_.Exception.Message; Update-Buttons }
})
$refreshButton.Add_Click({ try { Refresh-Adapters } catch { Show-UiError $_.Exception.Message } })
$removeVmwareButton.Add_Click({
    try {
        $message = 'Remove VMware Tools now? It is uninstalled silently (msiexec /qn /norestart). VMware Tools crashes on Proxmox/KVM, so removing it cleans up after migration. A reboot may be required. Continue?'
        if ([System.Windows.Forms.MessageBox]::Show($form, $message, 'Remove VMware Tools', 'YesNo', 'Warning', 'Button2') -ne 'Yes') { return }
        Start-Operation -Kind 'Vmware remove' -Parameters @{ Mode = 'Remove' }
    } catch { Show-UiError $_.Exception.Message; Update-Buttons }
})
$openButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    try {
        $dialog.Filter = 'Network export (*.json)|*.json'; $dialog.CheckFileExists = $true
        $dialog.InitialDirectory = [Environment]::GetFolderPath('Desktop')
        if (Test-Path -LiteralPath 'C:\Migration') { $dialog.InitialDirectory = 'C:\Migration' }
        if ($dialog.ShowDialog($form) -eq 'OK') { Load-Export $dialog.FileName }
    } catch { Show-UiError $_.Exception.Message } finally { $dialog.Dispose(); Update-Buttons }
})
$sourceCombo.Add_SelectedIndexChanged({ Show-SourceDetails })
$targetCombo.Add_SelectedIndexChanged({ Invalidate-Preview; Update-Buttons })
$removeCheck.Add_CheckedChanged({ Invalidate-Preview; Update-Buttons })
$previewButton.Add_Click({
    try {
        $key = Get-SelectionKey
        Start-Operation -Kind 'Dry run' -SelectionKey $key -Parameters @{
            Mode = 'Restore'; Path = $script:Ui.ExportPath
            SourceAlias = $sourceCombo.SelectedItem.Settings.Alias; TargetAlias = $targetCombo.SelectedItem.Alias
            RemoveOldAdapter = [bool]$removeCheck.Checked; WhatIf = $true
        }
    } catch { Invalidate-Preview; Show-UiError $_.Exception.Message; Update-Buttons }
})
$restoreButton.Add_Click({
    try {
        $key = Get-SelectionKey
        if ($key -ne $script:Ui.PreviewKey) { throw 'The selection has changed. Perform another dry run first.' }
        $message = "Apply the configuration from '$($sourceCombo.SelectedItem.Settings.Alias)' to '$($targetCombo.SelectedItem.Alias)' (MAC $($targetCombo.SelectedItem.Mac))?`r`n`r`nThe current IPv4 settings on this adapter will be replaced. Connectivity will be temporarily interrupted. Use the Proxmox console."
        if ($removeCheck.Checked) { $message += "`r`nThe exact absent old adapter will also be removed if it is still registered." }
        if ([System.Windows.Forms.MessageBox]::Show($form, $message, 'Confirm restore', 'YesNo', 'Warning', 'Button2') -ne 'Yes') { return }
        Start-Operation -Kind 'Restore' -SelectionKey $key -Parameters @{
            Mode = 'Restore'; Path = $script:Ui.ExportPath
            SourceAlias = $sourceCombo.SelectedItem.Settings.Alias; TargetAlias = $targetCombo.SelectedItem.Alias
            RemoveOldAdapter = [bool]$removeCheck.Checked
        }
    } catch { Invalidate-Preview; Show-UiError $_.Exception.Message; Update-Buttons }
})
$saveLogButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    try {
        $dialog.Filter = 'Log file (*.txt)|*.txt'; $dialog.FileName = "network-migration-$(Get-Date -Format yyyyMMdd-HHmmss).txt"
        if ($dialog.ShowDialog($form) -eq 'OK') { $logText.Text | Set-Content -LiteralPath $dialog.FileName -Encoding UTF8 }
    } catch { Show-UiError $_.Exception.Message } finally { $dialog.Dispose() }
})
$showLogButton.Add_Click({ Show-LogWindow })
$closeButton.Add_Click({ $form.Close() })
$form.Add_FormClosing({
    param($sender, $eventArgs)
    if ($script:Ui.Busy) {
        $eventArgs.Cancel = $true
        [System.Windows.Forms.MessageBox]::Show($form, 'An operation is still running. Wait for the result before closing.', 'Network migration') | Out-Null
    }
})
$form.Add_Shown({
    try {
        Refresh-Adapters
        Update-VmwareStatus
        if (Find-DesktopExport) {
            $statusLabel.Text = 'Loaded network export from the Desktop: ' + $script:Ui.ExportPath
        }
    } catch { Show-UiError $_.Exception.Message }
})
try { [void]$form.ShowDialog() } finally { $script:Ui.Exiting = $true; $timer.Dispose(); $logForm.Dispose(); $form.Dispose() }
