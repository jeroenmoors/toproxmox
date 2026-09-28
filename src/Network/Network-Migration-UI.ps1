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
$script:Ui = @{
    Busy = $false; Job = $null; ExportPath = ''; ExportHash = ''; Saved = $null
    PreviewKey = ''; LogDirectory = ''; Engine = $enginePath; PowerShell = $nativePs
    DriverEngine = (Join-Path $driverRoot 'Install-VirtioDrivers.ps1')
    DriverInstaller = $driverInstallerPath; DriverManifest = $driverManifestPath
    RebootRequired = $false; BootCheckedService = ''
    BootEngine = (Join-Path $driverRoot 'Prepare-VirtioBoot.ps1')
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
    $previewButton.Enabled = -not $busy -and -not $script:Ui.RebootRequired -and $null -ne $sourceCombo.SelectedItem -and $null -ne $targetCombo.SelectedItem
    $restoreButton.Enabled = $previewButton.Enabled -and -not [string]::IsNullOrWhiteSpace($script:Ui.PreviewKey)
    $checkBootButton.Enabled = -not $busy
    $prepareBootButton.Enabled = -not $busy -and -not $script:Ui.RebootRequired -and
        $script:Ui.BootCheckedService -eq $bootServiceCombo.SelectedItem.Service
    $installDriversButton.Enabled = -not $busy -and -not $script:Ui.RebootRequired -and
        (Test-Path -LiteralPath $script:Ui.DriverInstaller -PathType Leaf)
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'ToProxmox | Windows migration'
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size(980, 730)
$form.MinimumSize = New-Object System.Drawing.Size(860, 680)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$form.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
$form.AutoScaleMode = 'Dpi'
$form.BackColor = [Drawing.Color]::WhiteSmoke

$root = New-Object System.Windows.Forms.TableLayoutPanel
$root.Dock = 'Fill'; $root.Padding = New-Object System.Windows.Forms.Padding(16)
$root.ColumnCount = 1; $root.RowCount = 7
$root.AutoScroll = $true
[void]$root.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
# Text rows must include the label's preferred height AND margins. Fixed
# 42px rows clipped the second intro line even at the normal desktop scale.
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 360)))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100)))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
$form.Controls.Add($root)
$title = New-Label 'Prepare Windows for Proxmox'
$title.Font = New-Object System.Drawing.Font('Segoe UI', 18, [Drawing.FontStyle]::Bold)
$root.Controls.Add($title, 0, 0)
$intro = New-Label "Computer: $env:COMPUTERNAME  |  Administrator`r`nRestore using the Proxmox console. Network connectivity will be temporarily interrupted."
$root.Controls.Add($intro, 0, 1)

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = 'Fill'
$exportTab = New-Object System.Windows.Forms.TabPage('1. Before migration')
$restoreTab = New-Object System.Windows.Forms.TabPage('2. After migration')
$driversTab = New-Object System.Windows.Forms.TabPage('3. VirtIO drivers')
$bootTab = New-Object System.Windows.Forms.TabPage('Boot preparation')
$tabs.TabPages.AddRange(@($exportTab, $restoreTab, $driversTab, $bootTab))
$root.Controls.Add($tabs, 0, 2)

$exportLayout = New-Object System.Windows.Forms.TableLayoutPanel
$exportLayout.Dock = 'Fill'; $exportLayout.Padding = New-Object System.Windows.Forms.Padding(10)
$exportLayout.ColumnCount = 1; $exportLayout.RowCount = 4
[void]$exportLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
[void]$exportLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
[void]$exportLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100)))
[void]$exportLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
[void]$exportLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
$exportTab.Controls.Add($exportLayout)
$exportLayout.Controls.Add((New-Label 'Save all ordinary network adapters while the VM is still running on VMware. Choose a new JSON file; existing exports are never overwritten.'), 0, 0)
$adapterText = New-ReadOnlyText
$adapterText.Font = New-Object System.Drawing.Font('Consolas', 10)
$exportLayout.Controls.Add($adapterText, 0, 1)
$exportActions = New-Object System.Windows.Forms.FlowLayoutPanel
$exportActions.AutoSize = $true; $exportActions.AutoSizeMode = 'GrowAndShrink'; $exportActions.Dock = 'Fill'
$refreshButton = New-Button 'Refresh adapters'
$exportButton = New-Button 'Save configuration...' 220
$exportActions.Controls.AddRange(@($refreshButton, $exportButton))
$exportLayout.Controls.Add($exportActions, 0, 2)
$exportLayout.Controls.Add((New-Label 'Keep a copy of the export outside the VM as well. After migration, do not replace the original export with a new one.'), 0, 3)

$restoreLayout = New-Object System.Windows.Forms.TableLayoutPanel
$restoreLayout.Dock = 'Fill'; $restoreLayout.Padding = New-Object System.Windows.Forms.Padding(10)
$restoreLayout.ColumnCount = 3; $restoreLayout.RowCount = 6
[void]$restoreLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Absolute', 145)))
[void]$restoreLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
[void]$restoreLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Absolute', 174)))
for ($row = 0; $row -lt 3; $row++) { [void]$restoreLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize'))) }
[void]$restoreLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100)))
[void]$restoreLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
[void]$restoreLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
$restoreTab.Controls.Add($restoreLayout)
$restoreLayout.Controls.Add((New-Label 'Source file'), 0, 0)
$pathText = New-Object System.Windows.Forms.TextBox
$pathText.ReadOnly = $true; $pathText.Dock = 'Fill'
$restoreLayout.Controls.Add($pathText, 1, 0)
$openButton = New-Button 'Open export...' 160
$restoreLayout.Controls.Add($openButton, 2, 0)
$restoreLayout.Controls.Add((New-Label 'Old adapter'), 0, 1)
$sourceCombo = New-Object System.Windows.Forms.ComboBox
$sourceCombo.Dock = 'Fill'; $sourceCombo.DropDownStyle = 'DropDownList'; $sourceCombo.DisplayMember = 'Label'
$restoreLayout.Controls.Add($sourceCombo, 1, 1); $restoreLayout.SetColumnSpan($sourceCombo, 2)
$restoreLayout.Controls.Add((New-Label 'New adapter'), 0, 2)
$targetCombo = New-Object System.Windows.Forms.ComboBox
$targetCombo.Dock = 'Fill'; $targetCombo.DropDownStyle = 'DropDownList'; $targetCombo.DisplayMember = 'Label'
$restoreLayout.Controls.Add($targetCombo, 1, 2); $restoreLayout.SetColumnSpan($targetCombo, 2)
$detailsText = New-ReadOnlyText
$restoreLayout.Controls.Add($detailsText, 0, 3); $restoreLayout.SetColumnSpan($detailsText, 3)
$removeCheck = New-Object System.Windows.Forms.CheckBox
$removeCheck.Text = 'Remove absent old adapter (only the exact adapter recorded in this export)'
$removeCheck.AutoSize = $true; $removeCheck.Dock = 'Fill'; $removeCheck.Checked = $false
$restoreLayout.Controls.Add($removeCheck, 0, 4); $restoreLayout.SetColumnSpan($removeCheck, 3)
$restoreActions = New-Object System.Windows.Forms.FlowLayoutPanel
$restoreActions.AutoSize = $true; $restoreActions.AutoSizeMode = 'GrowAndShrink'; $restoreActions.Dock = 'Fill'
$previewButton = New-Button '1. Dry run (no changes)' 260
$restoreButton = New-Button '2. Restore configuration' 240
$previewButton.Enabled = $false; $restoreButton.Enabled = $false
$restoreActions.Controls.AddRange(@($previewButton, $restoreButton))
$restoreLayout.Controls.Add($restoreActions, 0, 5); $restoreLayout.SetColumnSpan($restoreActions, 3)

$driversLayout = New-Object System.Windows.Forms.TableLayoutPanel
$driversLayout.Dock = 'Fill'; $driversLayout.Padding = New-Object System.Windows.Forms.Padding(10)
$driversLayout.ColumnCount = 1; $driversLayout.RowCount = 5; $driversLayout.AutoScroll = $true
[void]$driversLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
for ($row = 0; $row -lt 5; $row++) { [void]$driversLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize'))) }
$driversTab.Controls.Add($driversLayout)
$driversLayout.Controls.Add((New-Label 'Install VirtIO drivers and guest agents for Proxmox. Export your network settings first. You can open setup before migration or after booting the migrated VM.'), 0, 0)
$driversLayout.Controls.Add((New-Label 'Use the VM console: driver installation may interrupt networking. Complete the upstream installer window and restart Windows if requested.'), 0, 1)
$driversLayout.Controls.Add((New-Label 'After installation and any required restart, open Boot preparation to check the storage driver before shutting down for migration.'), 0, 2)
$driverStatusLabel = New-Label ''
if (Test-Path -LiteralPath $script:Ui.DriverInstaller -PathType Leaf) {
    $driverStatusLabel.Text = "VirtIO Guest Tools $($driverManifest.Version) available. No installer download is needed on this VM."
} else {
    $driverStatusLabel.Text = 'Driver installer not included. Build or download a package with drivers using: .\build.ps1 package'
}
$driversLayout.Controls.Add($driverStatusLabel, 0, 3)
$installDriversButton = New-Button 'Install VirtIO drivers...' 240
$driversLayout.Controls.Add($installDriversButton, 0, 4)

$bootLayout = New-Object System.Windows.Forms.TableLayoutPanel
$bootLayout.Dock = 'Fill'; $bootLayout.Padding = New-Object System.Windows.Forms.Padding(10)
$bootLayout.ColumnCount = 1; $bootLayout.RowCount = 5; $bootLayout.AutoScroll = $true
[void]$bootLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
for ($row = 0; $row -lt 5; $row++) { [void]$bootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize'))) }
$bootTab.Controls.Add($bootLayout)
$bootLayout.Controls.Add((New-Label 'Before migration: install the drivers, complete any required restart, then choose the controller that will host the Windows boot disk in Proxmox.'), 0, 0)
$bootLayout.Controls.Add((New-Label 'Preparation checks the installed storage driver, saves the original startup values and enables Boot Start. NetKVM keeps its normal network-driver settings. A successful check is not a boot test.'), 0, 1)
$bootServiceCombo = New-Object System.Windows.Forms.ComboBox
$bootServiceCombo.Dock = 'Fill'; $bootServiceCombo.DropDownStyle = 'DropDownList'; $bootServiceCombo.DisplayMember = 'Label'
[void]$bootServiceCombo.Items.Add([PSCustomObject]@{ Label = 'VirtIO SCSI / VirtIO SCSI single (vioscsi)'; Service = 'vioscsi' })
[void]$bootServiceCombo.Items.Add([PSCustomObject]@{ Label = 'VirtIO Block (viostor)'; Service = 'viostor' })
$bootServiceCombo.SelectedIndex = 0
$bootLayout.Controls.Add($bootServiceCombo, 0, 2)
$bootActions = New-Object System.Windows.Forms.FlowLayoutPanel
$bootActions.AutoSize = $true; $bootActions.Dock = 'Fill'
$checkBootButton = New-Button '1. Check boot settings' 220
$prepareBootButton = New-Button '2. Prepare boot settings...' 250
$prepareBootButton.Enabled = $false
$bootActions.Controls.AddRange(@($checkBootButton, $prepareBootButton))
$bootLayout.Controls.Add($bootActions, 0, 3)
$bootStatusLabel = New-Label 'Check first. After preparation, shut down for migration. If Windows boots on VMware again, recheck the settings before migrating.'
$bootLayout.Controls.Add($bootStatusLabel, 0, 4)

$root.Controls.Add((New-Label 'IPv4 + default routes. Additional static routes, manual IPv6 and teaming require separate handling.'), 0, 3)
$logText = New-ReadOnlyText
$logText.Font = New-Object System.Drawing.Font('Consolas', 9)
$logText.MinimumSize = New-Object System.Drawing.Size(0, 80)
$logText.WordWrap = $false; $logText.ScrollBars = 'Both'
$root.Controls.Add($logText, 0, 4)
$statusLabel = New-Label 'Ready. Viewing settings does not change anything.'
$root.Controls.Add($statusLabel, 0, 5)
$footer = New-Object System.Windows.Forms.FlowLayoutPanel
$footer.AutoSize = $true; $footer.AutoSizeMode = 'GrowAndShrink'; $footer.Dock = 'Fill'; $footer.FlowDirection = 'RightToLeft'
$closeButton = New-Button 'Close' 100
$saveLogButton = New-Button 'Save log...' 180
$saveLogButton.Enabled = $false
$footer.Controls.AddRange(@($closeButton, $saveLogButton))
$root.Controls.Add($footer, 0, 6)

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
function Start-Operation([string]$Kind, [hashtable]$Parameters, [string]$SelectionKey = '') {
    if ($script:Ui.Busy) { return }
    $logRoot = Join-Path $env:ProgramData 'NetworkMigration\Logs'
    $opDir = Join-Path $logRoot ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $opDir -Force | Out-Null
    $transcriptPath = Join-Path $opDir 'operation.log'
    $resultPath = Join-Path $opDir 'result.json'
    if ($Kind -in @('Drivers', 'Boot check', 'Boot prepare')) { $script:Ui.BootCheckedService = '' }
    if ($Kind -eq 'Boot prepare') { $Parameters['BackupDirectory'] = $opDir }
    if ($Kind -eq 'Drivers') { $Parameters['LogPath'] = Join-Path $opDir 'virtio-setup.log' }
    $payload = @{
        Engine = $(if ($Kind -eq 'Drivers') { $script:Ui.DriverEngine } elseif ($Kind -in @('Boot check', 'Boot prepare')) { $script:Ui.BootEngine } else { $script:Ui.Engine })
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
    if ($payload.Kind -in @('Drivers', 'Boot check', 'Boot prepare')) {
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
            if ($script:Ui.RebootRequired) {
                [System.Windows.Forms.MessageBox]::Show($form, $result.Message, 'Restart required', 'OK', 'Information') | Out-Null
            }
        } elseif ($job.Kind -in @('Boot check', 'Boot prepare')) {
            $bootStatusLabel.Text = $result.Message
            $statusLabel.Text = $result.Message
            if ($job.Kind -eq 'Boot check' -and $result.CanPrepare) {
                $script:Ui.BootCheckedService = $job.Parameters.Service
            }
        } elseif ($job.Kind -eq 'Dry run') {
            $script:Ui.PreviewKey = $job.Key
            $statusLabel.Text = 'Dry run succeeded. No settings were changed. You can now restore the configuration.'
        } elseif ($job.Kind -eq 'Export') {
            Load-Export $job.Parameters.Path
            $statusLabel.Text = 'Export saved: ' + $job.Parameters.Path
        } else {
            Refresh-Adapters
            $statusLabel.Text = 'Restore completed. Check connectivity, DNS and the network profile; test again after a reboot.'
        }
    } catch {
        Invalidate-Preview
        Show-UiError $_.Exception.Message
    } finally {
        $job.Process.Dispose(); $script:Ui.Job = $null; $script:Ui.Busy = $false
        Update-Buttons
    }
})

$bootServiceCombo.Add_SelectedIndexChanged({
    $script:Ui.BootCheckedService = ''
    $bootStatusLabel.Text = 'Controller selection changed. Check boot settings again.'
    Update-Buttons
})
$checkBootButton.Add_Click({
    try {
        Start-Operation -Kind 'Boot check' -Parameters @{ Mode = 'Check'; Service = $bootServiceCombo.SelectedItem.Service }
    } catch { Show-UiError $_.Exception.Message; Update-Buttons }
})
$prepareBootButton.Add_Click({
    try {
        $service = $bootServiceCombo.SelectedItem.Service
        if ($script:Ui.BootCheckedService -ne $service) { throw 'Check the selected storage driver first.' }
        $message = "Prepare $service for the Windows boot disk? The tool will back up the original values and set Start and any existing StartOverride value named 0 to Boot Start. Keep a VM backup and console access. After preparation, shut down for migration. This does not guarantee a successful boot on different hardware."
        if ([System.Windows.Forms.MessageBox]::Show($form, $message, 'Prepare storage boot driver', 'YesNo', 'Warning', 'Button2') -ne 'Yes') { return }
        Start-Operation -Kind 'Boot prepare' -Parameters @{ Mode = 'Prepare'; Service = $service }
    } catch { Show-UiError $_.Exception.Message; Update-Buttons }
})
$installDriversButton.Add_Click({
    try {
        $message = 'Open VirtIO Guest Tools setup? It can install drivers and guest agents, including QEMU Guest Agent and SPICE components. Export your network settings first and use the VM console. Networking may be interrupted. Automatic restarts are suppressed.'
        if ([System.Windows.Forms.MessageBox]::Show($form, $message, 'Install VirtIO drivers', 'YesNo', 'Warning', 'Button2') -ne 'Yes') { return }
        Start-Operation -Kind 'Drivers' -Parameters @{
            InstallerPath = $script:Ui.DriverInstaller; ManifestPath = $script:Ui.DriverManifest
        }
    } catch { Show-UiError $_.Exception.Message; Update-Buttons }
})
$refreshButton.Add_Click({ try { Refresh-Adapters } catch { Show-UiError $_.Exception.Message } })
$exportButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    try {
        $dialog.Filter = 'Network export (*.json)|*.json'; $dialog.DefaultExt = 'json'; $dialog.AddExtension = $true
        $dialog.FileName = "$env:COMPUTERNAME-network-$(Get-Date -Format yyyyMMdd-HHmmss).json"
        if (Test-Path -LiteralPath 'C:\Migration') { $dialog.InitialDirectory = 'C:\Migration' }
        if ($dialog.ShowDialog($form) -ne 'OK') { return }
        if (Test-Path -LiteralPath $dialog.FileName) { throw 'This file already exists. Choose a new file name.' }
        Start-Operation -Kind 'Export' -Parameters @{ Mode = 'Export'; Path = $dialog.FileName }
    } catch { Show-UiError $_.Exception.Message } finally { $dialog.Dispose() }
})
$openButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    try {
        $dialog.Filter = 'Network export (*.json)|*.json'; $dialog.CheckFileExists = $true
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
$closeButton.Add_Click({ $form.Close() })
$form.Add_FormClosing({
    param($sender, $eventArgs)
    if ($script:Ui.Busy) {
        $eventArgs.Cancel = $true
        [System.Windows.Forms.MessageBox]::Show($form, 'An operation is still running. Wait for the result before closing.', 'Network migration') | Out-Null
    }
})
$form.Add_Shown({ try { Refresh-Adapters } catch { Show-UiError $_.Exception.Message } })
try { [void]$form.ShowDialog() } finally { $timer.Dispose(); $form.Dispose() }
