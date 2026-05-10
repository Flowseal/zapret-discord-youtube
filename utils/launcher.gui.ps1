#Requires -Version 5.1
<#
.SYNOPSIS
  WPF-based GUI for codeDPI launcher.
.DESCRIPTION
  Loads launcher.lib.ps1, builds a single-window WPF UI for:
    - DPI services (winws.exe via zapret)
    - Strategy picker + Start/Stop bypass
    - Cloudflare WARP (install / connect / mode / auto-start with bypass)
    - Geo-blocked services routed via WARP using a generated PAC file
    - Custom VPN (WireGuard import, system proxy)
    - Tools (custom domain editor, list updates, diagnostics)
    - Log box
#>

$ErrorActionPreference = 'Stop'

# Top-level safety net: any uncaught error gets logged and shown to the user
# instead of silently closing the cmd window before they can read it.
trap {
    $err = $_
    $msg = "$($err.Exception.GetType().Name): $($err.Exception.Message)"
    try {
        $logPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'launcher.log'
        $line = "[{0}] gui FATAL: {1}`n{2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg, $err.ScriptStackTrace
        Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
    } catch { }
    Write-Host ''
    Write-Host '=====================================================================' -ForegroundColor Red
    Write-Host '  codeDPI GUI — FATAL ERROR' -ForegroundColor Red
    Write-Host '=====================================================================' -ForegroundColor Red
    Write-Host $msg -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'Stack:' -ForegroundColor DarkGray
    Write-Host $err.ScriptStackTrace -ForegroundColor DarkGray
    Write-Host ''
    Write-Host 'Press ENTER to close this window...' -ForegroundColor DarkGray
    try { [void][Console]::ReadLine() } catch { Start-Sleep -Seconds 30 }
    exit 1
}

. (Join-Path $PSScriptRoot 'launcher.lib.ps1')

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
Add-Type -AssemblyName Microsoft.VisualBasic

# ============================================================================
# XAML
# ============================================================================
$xamlText = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="codeDPI — settings"
        Width="760" Height="780"
        Background="#1b1d22" Foreground="#dddddd"
        FontFamily="Segoe UI" FontSize="12"
        WindowStartupLocation="CenterScreen">
  <Window.Resources>
    <Style TargetType="Border" x:Key="Card">
      <Setter Property="BorderBrush" Value="#3a3d44"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="6"/>
      <Setter Property="Padding" Value="12"/>
      <Setter Property="Margin" Value="0,0,0,10"/>
      <Setter Property="Background" Value="#23262d"/>
    </Style>
    <Style TargetType="TextBlock" x:Key="SectionTitle">
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Foreground" Value="#ffffff"/>
      <Setter Property="Margin" Value="0,0,0,6"/>
    </Style>
    <Style TargetType="TextBlock" x:Key="Hint">
      <Setter Property="Foreground" Value="#808591"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="Margin" Value="0,0,0,6"/>
    </Style>
    <Style TargetType="Button">
      <Setter Property="Padding" Value="10,4"/>
      <Setter Property="Margin" Value="0,0,6,0"/>
      <Setter Property="Background" Value="#33373f"/>
      <Setter Property="Foreground" Value="#dddddd"/>
      <Setter Property="BorderBrush" Value="#444"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Cursor" Value="Hand"/>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Margin" Value="0,2,0,2"/>
      <Setter Property="Foreground" Value="#dddddd"/>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="Background" Value="#33373f"/>
      <Setter Property="Foreground" Value="#dddddd"/>
      <Setter Property="BorderBrush" Value="#444"/>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="#15171b"/>
      <Setter Property="Foreground" Value="#cdf3cd"/>
      <Setter Property="BorderBrush" Value="#444"/>
      <Setter Property="FontFamily" Value="Consolas"/>
      <Setter Property="FontSize" Value="11"/>
    </Style>
  </Window.Resources>

  <DockPanel Margin="14">

    <!-- Header -->
    <StackPanel DockPanel.Dock="Top" Margin="0,0,0,10">
      <TextBlock Text="zapret all-in-one" FontSize="20" FontWeight="Bold" Foreground="#ffffff"/>
      <TextBlock x:Name="lblStatusLine" Text="loading..." Foreground="#a0a4ad" FontSize="11" Margin="0,2,0,0"/>
    </StackPanel>

    <!-- Log (bottom) -->
    <Border DockPanel.Dock="Bottom" Style="{StaticResource Card}" Padding="6">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="120"/>
        </Grid.RowDefinitions>
        <DockPanel Grid.Row="0">
          <TextBlock Text="Log" Style="{StaticResource SectionTitle}" Margin="2,0,0,2"/>
          <Button x:Name="btnLogClear" Content="Clear" DockPanel.Dock="Right" Padding="6,1" Margin="0,0,0,2"/>
        </DockPanel>
        <TextBox x:Name="txtLog" Grid.Row="1" IsReadOnly="True"
                 VerticalScrollBarVisibility="Auto"
                 TextWrapping="NoWrap"/>
      </Grid>
    </Border>

    <!-- Main content (scrollable) -->
    <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
      <StackPanel>

        <!-- DPI services -->
        <Border Style="{StaticResource Card}">
          <StackPanel>
            <TextBlock Text="DPI bypass (zapret) — services" Style="{StaticResource SectionTitle}"/>
            <TextBlock Style="{StaticResource Hint}" Text="Domains that get DPI desync via winws.exe. YouTube and Discord are always on (they live in upstream lists). Toggle the rest. Changes are saved and applied immediately."/>
            <ItemsControl x:Name="pnlServices">
              <ItemsControl.ItemsPanel>
                <ItemsPanelTemplate>
                  <UniformGrid Columns="2"/>
                </ItemsPanelTemplate>
              </ItemsControl.ItemsPanel>
            </ItemsControl>
          </StackPanel>
        </Border>

        <!-- Strategy + Start/Stop -->
        <Border Style="{StaticResource Card}">
          <StackPanel>
            <TextBlock Text="Strategy + Start / Stop" Style="{StaticResource SectionTitle}"/>
            <TextBlock Style="{StaticResource Hint}" Text="Different RU providers respond to different desync techniques. If your current strategy stops working, try ALT / FAKE TLS AUTO / SIMPLE FAKE variants until traffic is restored."/>
            <DockPanel Margin="0,0,0,8">
              <TextBlock Text="Strategy:" VerticalAlignment="Center" Margin="0,0,8,0"/>
              <ComboBox x:Name="cmbStrategy"/>
            </DockPanel>
            <StackPanel Orientation="Horizontal">
              <Button x:Name="btnStart"        Content="▶ Start bypass"   Background="#2d6a4f"/>
              <Button x:Name="btnStop"         Content="■ Stop bypass"    Background="#793a3a"/>
              <Button x:Name="btnInstallSvc"   Content="Install as Windows service…"/>
            </StackPanel>
          </StackPanel>
        </Border>

        <!-- Cloudflare WARP -->
        <Border Style="{StaticResource Card}">
          <StackPanel>
            <TextBlock Text="Cloudflare WARP" Style="{StaticResource SectionTitle}"/>
            <TextBlock Style="{StaticResource Hint}" Text="Free, no signup. Run by Cloudflare. Gives you a different exit IP. Used here to reach services that geo-block RU IPs. Auto-start can chain WARP onto every Start bypass click."/>
            <TextBlock x:Name="lblWarpStatus" Margin="0,0,0,8" Foreground="#a0a4ad"/>
            <CheckBox x:Name="chkWarpAutostart" Content="Auto-start WARP when starting bypass (proxy mode + PAC routing)"/>
            <CheckBox x:Name="chkGeoRouting"    Content="Apply PAC routing for geo-blocked services (system AutoConfigURL)"/>
            <DockPanel Margin="0,8,0,8">
              <TextBlock Text="Manual mode:" VerticalAlignment="Center" Margin="0,0,8,0"/>
              <ComboBox x:Name="cmbWarpMode" Width="160">
                <ComboBoxItem>warp</ComboBoxItem>
                <ComboBoxItem>warp+doh</ComboBoxItem>
                <ComboBoxItem>doh</ComboBoxItem>
                <ComboBoxItem>proxy</ComboBoxItem>
              </ComboBox>
              <Button x:Name="btnWarpApplyMode" Content="Apply mode" DockPanel.Dock="Left" Margin="6,0,0,0"/>
            </DockPanel>
            <StackPanel Orientation="Horizontal">
              <Button x:Name="btnWarpInstall"     Content="Install (winget)"/>
              <Button x:Name="btnWarpConnect"     Content="Connect"/>
              <Button x:Name="btnWarpDisconnect"  Content="Disconnect"/>
              <Button x:Name="btnWarpStatusShow"  Content="Show full status"/>
            </StackPanel>
          </StackPanel>
        </Border>

        <!-- Geo-blocked services -->
        <Border Style="{StaticResource Card}">
          <StackPanel>
            <TextBlock Text="Geo-blocked services (routed via WARP)" Style="{StaticResource SectionTitle}"/>
            <TextBlock Style="{StaticResource Hint}" Text="These domains zapret CANNOT unblock — they refuse RU IPs server-side. Selected ones are routed through WARP via a generated PAC file (works for Chrome / Edge / IE). Firefox needs manual PAC URL — see README."/>
            <ItemsControl x:Name="pnlGeo">
              <ItemsControl.ItemsPanel>
                <ItemsPanelTemplate>
                  <UniformGrid Columns="2"/>
                </ItemsPanelTemplate>
              </ItemsControl.ItemsPanel>
            </ItemsControl>
            <StackPanel Orientation="Horizontal" Margin="0,8,0,0">
              <Button x:Name="btnGeoRebuild"     Content="Rebuild PAC now"/>
              <Button x:Name="btnGeoEditCustom"  Content="Edit custom geo list…"/>
              <Button x:Name="btnGeoCopyUrl"     Content="Copy PAC URL (for Firefox)"/>
            </StackPanel>
          </StackPanel>
        </Border>

        <!-- Custom VPN -->
        <Border Style="{StaticResource Card}">
          <StackPanel>
            <TextBlock Text="Custom VPN / Proxy (your own)" Style="{StaticResource SectionTitle}"/>
            <TextBlock Style="{StaticResource Hint}" Text="For YOUR OWN trusted VPN/proxy (your VPS, paid VPN, etc.). We deliberately do NOT ship random public proxies — they are honeypots."/>
            <TextBlock x:Name="lblWgStatus" Margin="0,0,0,8" Foreground="#a0a4ad"/>
            <StackPanel Orientation="Horizontal" Margin="0,0,0,6">
              <Button x:Name="btnWgImport"        Content="Import WireGuard .conf…"/>
              <Button x:Name="btnWgStop"          Content="Stop / remove tunnels"/>
              <Button x:Name="btnWgInstall"       Content="Install WireGuard (winget)"/>
            </StackPanel>
            <StackPanel Orientation="Horizontal">
              <Button x:Name="btnProxySet"        Content="Set system SOCKS5/HTTP…"/>
              <Button x:Name="btnProxyDisable"    Content="Disable system proxy"/>
              <Button x:Name="btnOpenCustomDir"   Content="Open custom-vpn folder"/>
            </StackPanel>
          </StackPanel>
        </Border>

        <!-- Tools -->
        <Border Style="{StaticResource Card}">
          <StackPanel>
            <TextBlock Text="Tools" Style="{StaticResource SectionTitle}"/>
            <StackPanel Orientation="Horizontal" Margin="0,0,0,4">
              <Button x:Name="btnConnTest"    Content="Run connectivity test"/>
              <Button x:Name="btnEditCustom"  Content="Edit custom DPI domains"/>
              <Button x:Name="btnUpdateLists" Content="Update domain lists"/>
            </StackPanel>
            <StackPanel Orientation="Horizontal">
              <Button x:Name="btnDiagnostics" Content="Diagnostics (service.bat)"/>
              <Button x:Name="btnOpenCli"     Content="Open old CLI launcher"/>
            </StackPanel>
          </StackPanel>
        </Border>

      </StackPanel>
    </ScrollViewer>

  </DockPanel>
</Window>
'@

# ============================================================================
# Load XAML
# ============================================================================
$reader = New-Object System.Xml.XmlNodeReader ([xml]$xamlText)
$Script:window = [Windows.Markup.XamlReader]::Load($reader)

function Find($name) { $Script:window.FindName($name) }

$Script:txtLog            = Find 'txtLog'
$Script:lblStatusLine     = Find 'lblStatusLine'
$Script:pnlServices       = Find 'pnlServices'
$Script:pnlGeo            = Find 'pnlGeo'
$Script:cmbStrategy       = Find 'cmbStrategy'
$Script:cmbWarpMode       = Find 'cmbWarpMode'
$Script:lblWarpStatus     = Find 'lblWarpStatus'
$Script:lblWgStatus       = Find 'lblWgStatus'
$Script:chkWarpAutostart  = Find 'chkWarpAutostart'
$Script:chkGeoRouting     = Find 'chkGeoRouting'

# ============================================================================
# Logging — sink writes to txtLog
# ============================================================================
$Script:LogSink = {
    param([string]$msg, [string]$color)
    if ([string]::IsNullOrEmpty($msg)) { return }
    $time = (Get-Date).ToString('HH:mm:ss')
    $Script:window.Dispatcher.Invoke([Action]{
        $Script:txtLog.AppendText("[$time] $msg`r`n")
        $Script:txtLog.ScrollToEnd()
    })
}

# ============================================================================
# Load config
# ============================================================================
$Script:Cfg = Read-Config

# ============================================================================
# Build dynamic checkboxes
# ============================================================================
$Script:ServiceCheckboxes = @{}
foreach ($key in $Services.Keys) {
    $svc = $Services[$key]
    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Content = $svc.Name
    $cb.Tag = $key
    if ($svc.AlwaysOn) {
        $cb.IsChecked = $true
        $cb.IsEnabled = $false
        $cb.Opacity = 0.6
        $cb.ToolTip = 'Always on (built into upstream zapret strategies)'
    } else {
        $cb.IsChecked = ($Script:Cfg["service_$key"] -eq '1')
    }
    $cb.Add_Click({
        $k = $this.Tag
        $Script:Cfg["service_$k"] = if ($this.IsChecked) { '1' } else { '0' }
        Save-Config $Script:Cfg
        Apply-Services $Script:Cfg
        Write-LauncherLog "DPI service '$($Services[$k].Name)' -> $(if ($this.IsChecked) { 'ON' } else { 'OFF' })" 'Cyan'
    })
    $null = $Script:pnlServices.Items.Add($cb)
    $Script:ServiceCheckboxes[$key] = $cb
}

$Script:GeoCheckboxes = @{}
foreach ($key in $GeoServices.Keys) {
    $svc = $GeoServices[$key]
    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Content = $svc.Name
    $cb.Tag = $key
    $cb.IsChecked = ($Script:Cfg["geo_$key"] -eq '1')
    $cb.Add_Click({
        $k = $this.Tag
        $Script:Cfg["geo_$k"] = if ($this.IsChecked) { '1' } else { '0' }
        Save-Config $Script:Cfg
        # If WARP+PAC currently enabled, rebuild on the fly.
        if (Test-PacEnabled $Script:Cfg) {
            Write-PacFile $Script:Cfg | Out-Null
            Write-LauncherLog "PAC rebuilt: '$($GeoServices[$k].Name)' -> $(if ($this.IsChecked) { 'ON' } else { 'OFF' })" 'Cyan'
        } else {
            Write-LauncherLog "Geo service '$($GeoServices[$k].Name)' -> $(if ($this.IsChecked) { 'ON' } else { 'OFF' }) (apply on next Start bypass)" 'DarkGray'
        }
    })
    $null = $Script:pnlGeo.Items.Add($cb)
    $Script:GeoCheckboxes[$key] = $cb
}

# Strategy combobox
foreach ($f in (Get-StrategyFiles)) { $null = $Script:cmbStrategy.Items.Add($f) }
$Script:cmbStrategy.SelectedItem = $Script:Cfg.strategy
$Script:cmbStrategy.Add_SelectionChanged({
    if ($Script:cmbStrategy.SelectedItem) {
        $Script:Cfg.strategy = [string]$Script:cmbStrategy.SelectedItem
        Save-Config $Script:Cfg
        Write-LauncherLog "Strategy: $($Script:Cfg.strategy)" 'Cyan'
    }
})

# WARP mode combobox — match by Content
foreach ($it in $Script:cmbWarpMode.Items) {
    if ([string]$it.Content -eq $Script:Cfg.warp_mode) {
        $Script:cmbWarpMode.SelectedItem = $it
        break
    }
}

# Auto-start toggles
$Script:chkWarpAutostart.IsChecked = ($Script:Cfg.warp_autostart -eq '1')
$Script:chkGeoRouting.IsChecked    = ($Script:Cfg.geo_routing    -eq '1')
$Script:chkWarpAutostart.Add_Click({
    $Script:Cfg.warp_autostart = if ($this.IsChecked) { '1' } else { '0' }
    Save-Config $Script:Cfg
    Write-LauncherLog "WARP auto-start: $(if ($this.IsChecked) { 'ON' } else { 'OFF' })" 'Cyan'
})
$Script:chkGeoRouting.Add_Click({
    $Script:Cfg.geo_routing = if ($this.IsChecked) { '1' } else { '0' }
    Save-Config $Script:Cfg
    Write-LauncherLog "PAC geo-routing: $(if ($this.IsChecked) { 'ON' } else { 'OFF' })" 'Cyan'
})

# ============================================================================
# Status updater (DispatcherTimer)
# ============================================================================
# Cached pieces — refreshed on a slower cadence than the status timer to avoid
# hammering Get-Service every 3 seconds on machines with many services.
$Script:WgCacheTick    = 0
$Script:WgInstalledExe = $null
$Script:WgTunnels      = @()

function Update-Status {
    $bypass = if (Test-WinwsRunning) { 'RUNNING' } else { 'stopped' }
    $svc    = if (Test-ServiceInstalled 'zapret') {
                  if (Test-ServiceRunning 'zapret') { 'service running' } else { 'service installed (stopped)' }
              } else { 'no service' }
    $warp   = Get-WarpStatus
    $warpStr = if (-not $warp.Installed) { 'not installed' }
               elseif ($warp.Connected)  { 'connected' }
               else                      { 'disconnected' }

    $pac = Test-PacEnabled $Script:Cfg
    $pacSrv = Test-PacServerRunning
    $pacStr = if ($pac -and $pacSrv) { 'PAC active' }
              elseif ($pac)          { 'PAC reg set, server DOWN' }
              elseif ($pacSrv)       { 'PAC server up (not registered)' }
              else                   { 'PAC off' }

    $Script:lblStatusLine.Text = "Bypass: $bypass   |   Win service: $svc   |   WARP: $warpStr   |   $pacStr"
    $Script:lblWarpStatus.Text = "WARP: $warpStr"

    # Refresh WG cache every ~5th tick (~15 sec) — Get-Service can be slow.
    $Script:WgCacheTick++
    if ($Script:WgCacheTick -ge 5 -or -not $Script:WgInstalledExe) {
        $Script:WgInstalledExe = Get-WireGuardExe
        $Script:WgTunnels      = Get-WireGuardTunnels
        $Script:WgCacheTick    = 0
    }
    $proxy = Get-SystemProxyStatus
    $wgLine = "WireGuard: $(if ($Script:WgInstalledExe) { 'installed' } else { 'NOT installed' })"
    if ($Script:WgTunnels) { $wgLine += "   |   tunnels: $($Script:WgTunnels.Name -join ', ')" }
    if ($proxy.Enabled) { $wgLine += "   |   system proxy: $($proxy.Server)" }
    if ($proxy.AutoConfigURL) { $wgLine += "   |   AutoConfigURL set" }
    $Script:lblWgStatus.Text = $wgLine
}
Update-Status

$Script:timer = New-Object System.Windows.Threading.DispatcherTimer
$Script:timer.Interval = [TimeSpan]::FromSeconds(3)
$Script:timer.Add_Tick({ try { Update-Status } catch { } })
$Script:timer.Start()

# Stop the timer cleanly when the window is closed; otherwise the dispatcher
# keeps the process alive in some PS hosts.
$Script:window.Add_Closed({
    try { if ($Script:timer) { $Script:timer.Stop() } } catch { }
})

# ============================================================================
# Button wiring
# ============================================================================
$Script:Busy = $false
function Catch-Click([scriptblock]$body) {
    return {
        if ($Script:Busy) { return }
        $Script:Busy = $true
        try { & $body } catch { Write-LauncherLog "ERROR: $_" 'Red' }
        try { Update-Status } catch { }
        $Script:Busy = $false
    }.GetNewClosure()
}

# Wrap an action so the bypass buttons are disabled while it runs — prevents
# double-clicks from racing Start/Stop or a long warp-cli call.
function With-BypassBusy([scriptblock]$body) {
    return {
        if ($Script:Busy) { return }
        $Script:Busy = $true
        $btnA = Find 'btnStart'; $btnB = Find 'btnStop'
        try {
            $btnA.IsEnabled = $false
            $btnB.IsEnabled = $false
            & $body
        } catch {
            Write-LauncherLog "ERROR: $_" 'Red'
        } finally {
            $btnA.IsEnabled = $true
            $btnB.IsEnabled = $true
            try { Update-Status } catch { }
            $Script:Busy = $false
        }
    }.GetNewClosure()
}

# ---- Bypass ----
(Find 'btnStart').Add_Click( (With-BypassBusy {
    Write-LauncherLog 'Starting...' 'Yellow'
    $r = Start-Combined $Script:Cfg
    $col = if ($r.Bypass) { if ($r.Errors.Count -eq 0) { 'Green' } else { 'Yellow' } } else { 'Red' }
    Write-LauncherLog $r.Message $col
    if ($r.Errors.Count -gt 0) {
        foreach ($e in $r.Errors) { Write-LauncherLog "  $e" 'DarkYellow' }
    }
}) )

(Find 'btnStop').Add_Click( (With-BypassBusy {
    Write-LauncherLog 'Stopping...' 'Yellow'
    Stop-Combined $Script:Cfg
    Write-LauncherLog 'Stopped.' 'Green'
}) )

(Find 'btnInstallSvc').Add_Click( (Catch-Click {
    $bat = Join-Path $RepoRoot 'service.bat'
    if (-not (Test-Path -LiteralPath $bat)) { throw "service.bat not found at $bat" }
    Start-Process -FilePath 'cmd.exe' -ArgumentList @('/k', "call `"$bat`"")
    Write-LauncherLog 'Opened service.bat in a new window — use it to Install/Remove the Windows service.' 'Cyan'
}) )

# ---- WARP ----
(Find 'btnWarpInstall').Add_Click( (Catch-Click {
    Install-Warp | Out-Null
}) )

(Find 'btnWarpConnect').Add_Click( (Catch-Click {
    Connect-Warp
    Write-LauncherLog 'WARP: connect requested.' 'Cyan'
}) )

(Find 'btnWarpDisconnect').Add_Click( (Catch-Click {
    Disconnect-Warp
    Write-LauncherLog 'WARP: disconnect requested.' 'Cyan'
}) )

(Find 'btnWarpApplyMode').Add_Click( (Catch-Click {
    if ($Script:cmbWarpMode.SelectedItem) {
        $m = [string]$Script:cmbWarpMode.SelectedItem.Content
        Set-WarpMode $m
        $Script:Cfg.warp_mode = $m
        Save-Config $Script:Cfg
        Write-LauncherLog "WARP mode -> $m" 'Cyan'
    }
}) )

(Find 'btnWarpStatusShow').Add_Click( (Catch-Click {
    $st = Get-WarpStatus
    if ($st.Installed) {
        foreach ($l in ($st.Raw -split "`n")) { Write-LauncherLog $l 'DarkGray' }
    } else {
        Write-LauncherLog 'WARP is not installed.' 'Red'
    }
}) )

# ---- Geo ----
(Find 'btnGeoRebuild').Add_Click( (Catch-Click {
    $info = Write-PacFile $Script:Cfg
    # If PAC is currently active OR auto-routing is enabled, also (re)start the
    # localhost server + register AutoConfigURL so changes take effect now.
    if ((Test-PacEnabled $Script:Cfg) -or ($Script:Cfg.geo_routing -eq '1' -and $Script:Cfg.warp_autostart -eq '1')) {
        $srv = Start-PacServer $Script:Cfg
        Enable-PacAutoConfig $Script:Cfg | Out-Null
        Write-LauncherLog "PAC rebuilt: $($info.DomainCount) domain(s) -> WARP. Serving at $($srv.Url)" 'Green'
    } else {
        Write-LauncherLog "PAC rebuilt: $($info.DomainCount) domain(s) (offline; will be served on next Start)" 'Cyan'
    }
}) )

(Find 'btnGeoEditCustom').Add_Click( (Catch-Click {
    Open-CustomGeoDomains
}) )

(Find 'btnGeoCopyUrl').Add_Click( (Catch-Click {
    $u = Get-PacFileUrl $Script:Cfg
    [System.Windows.Clipboard]::SetText($u)
    Write-LauncherLog "PAC URL copied to clipboard: $u" 'Cyan'
    Write-LauncherLog "Firefox: about:preferences -> Network Settings -> Automatic proxy configuration URL -> paste." 'DarkGray'
    if (-not (Test-PacServerRunning)) {
        Write-LauncherLog 'Note: PAC server is not running yet. Press Start (or Connect WARP) first; otherwise Firefox will fail to load the URL.' 'Yellow'
    }
}) )

# ---- Custom VPN ----
(Find 'btnWgImport').Add_Click( (Catch-Click {
    if (-not (Test-Path $CustomDir)) { $null = New-Item -ItemType Directory -Path $CustomDir }
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = 'WireGuard config (*.conf)|*.conf'
    $dlg.InitialDirectory = $CustomDir
    if ($dlg.ShowDialog() -eq $true) {
        Install-WireGuardTunnel $dlg.FileName
        Write-LauncherLog "Imported WireGuard tunnel: $($dlg.FileName)" 'Green'
    }
}) )

(Find 'btnWgStop').Add_Click( (Catch-Click {
    $n = Stop-WireGuardTunnels
    Write-LauncherLog "Stopped $n WireGuard tunnel(s)." $(if ($n -gt 0) { 'Green' } else { 'DarkGray' })
}) )

(Find 'btnWgInstall').Add_Click( (Catch-Click {
    Install-WireGuard | Out-Null
}) )

(Find 'btnProxySet').Add_Click( (Catch-Click {
    $p = [Microsoft.VisualBasic.Interaction]::InputBox(
        "Examples:`r`n  socks=127.0.0.1:1080`r`n  http=proxy.example.com:8080`r`n  myproxy.example.com:3128",
        'Set system proxy', '')
    if ($p) {
        Set-SystemProxy $p
        Write-LauncherLog "System proxy set: $p" 'Green'
    }
}) )

(Find 'btnProxyDisable').Add_Click( (Catch-Click {
    Disable-SystemProxy
    Write-LauncherLog 'System proxy disabled.' 'Green'
}) )

(Find 'btnOpenCustomDir').Add_Click( (Catch-Click {
    if (-not (Test-Path $CustomDir)) { $null = New-Item -ItemType Directory -Path $CustomDir }
    Start-Process explorer.exe $CustomDir
}) )

# ---- Tools ----
(Find 'btnEditCustom').Add_Click(  (Catch-Click { Open-CustomDomains; Write-LauncherLog 'Opened lists/list-custom.txt — save and close, then re-Start bypass.' 'DarkGray' }) )
(Find 'btnUpdateLists').Add_Click( (Catch-Click { Update-Lists }) )
(Find 'btnDiagnostics').Add_Click( (Catch-Click { Run-Diagnostics }) )
(Find 'btnOpenCli').Add_Click( (Catch-Click {
    $bat = Join-Path $RepoRoot 'launcher.bat'
    Start-Process -FilePath 'cmd.exe' -ArgumentList @('/k', "call `"$bat`" admin cli")
}) )
(Find 'btnConnTest').Add_Click( (Catch-Click {
    Write-LauncherLog 'Connectivity smoke-test: probing PAC server, WARP proxy, DPI path (youtube), Geo path (chatgpt via WARP)...' 'Yellow'
    $t = Test-Connectivity $Script:Cfg
    foreach ($k in 'PacServer','Warp','Dpi','Geo') {
        $row = $t[$k]
        $col = if ($row.Ok) { 'Green' } else { 'Yellow' }
        $tag = if ($row.Ok) { 'OK' } else { 'FAIL' }
        Write-LauncherLog ("{0,-10} [{1}] {2}" -f $k, $tag, $row.Detail) $col
    }
}) )

(Find 'btnLogClear').Add_Click({ $Script:txtLog.Clear() })

# ============================================================================
# Apply current toggles to lists/list-general-user.txt at startup
# ============================================================================
try {
    Apply-Services $Script:Cfg
    Write-LauncherLog "Loaded config from $ConfigPath" 'DarkGray'
    Write-LauncherLog "DPI services applied -> lists/list-general-user.txt" 'DarkGray'
} catch {
    Write-LauncherLog "Startup error: $_" 'Red'
}

# ============================================================================
# Show window
# ============================================================================
[void]$Script:window.ShowDialog()
