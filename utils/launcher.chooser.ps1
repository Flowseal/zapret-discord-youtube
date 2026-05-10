#Requires -Version 5.1
<#
.SYNOPSIS
  Minimal launcher chooser — single small WPF window with 4 actions.
.DESCRIPTION
  One-screen entry point for the most common things:
    [▶]  Start       — apply current config, start zapret + WARP + PAC.
    [■]  Stop        — tear it all down.
    [⚙]  Settings    — open the full WPF launcher (services, strategy, WARP, PAC, custom VPN).
    [✓]  Test        — connectivity smoke-test (zapret + WARP + PAC + geo).

  Auto-refreshes the status line every 3 seconds.
#>

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

. (Join-Path $PSScriptRoot 'launcher.lib.ps1')
$Script:Cfg = Read-Config

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="codeDPI" Width="380" Height="320"
        WindowStartupLocation="CenterScreen"
        ResizeMode="NoResize"
        Background="#1e1e1e"
        FontFamily="Segoe UI" FontSize="13"
        Foreground="#e0e0e0">
    <Window.Resources>
        <Style x:Key="ActionButton" TargetType="Button">
            <Setter Property="Background" Value="#2d2d30"/>
            <Setter Property="Foreground" Value="#e0e0e0"/>
            <Setter Property="BorderBrush" Value="#3f3f46"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="12,10"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Margin" Value="4"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="b"
                                Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="6">
                            <ContentPresenter HorizontalAlignment="Center"
                                              VerticalAlignment="Center"
                                              Margin="{TemplateBinding Padding}"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="b" Property="Background" Value="#3a3a3d"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="b" Property="Background" Value="#252526"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Foreground" Value="#666"/>
                                <Setter TargetName="b" Property="Background" Value="#252526"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>
    <Grid Margin="16">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <StackPanel Grid.Row="0" Margin="4,0,4,12">
            <StackPanel Orientation="Horizontal">
                <Ellipse x:Name="dot" Width="10" Height="10" Fill="#666" VerticalAlignment="Center"/>
                <TextBlock x:Name="lblStatus" Text="loading..." Margin="8,0,0,0" FontWeight="SemiBold"/>
            </StackPanel>
            <TextBlock x:Name="lblDetail" Text="" FontSize="11" Foreground="#999" Margin="18,2,0,0"/>
        </StackPanel>
        <Grid Grid.Row="1">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <Grid.RowDefinitions>
                <RowDefinition Height="*"/>
                <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <Button x:Name="btnStart"    Grid.Row="0" Grid.Column="0" Style="{StaticResource ActionButton}" Content="▶  Запустить"/>
            <Button x:Name="btnStop"     Grid.Row="0" Grid.Column="1" Style="{StaticResource ActionButton}" Content="■  Остановить"/>
            <Button x:Name="btnSettings" Grid.Row="1" Grid.Column="0" Style="{StaticResource ActionButton}" Content="⚙  Настройки"/>
            <Button x:Name="btnTest"     Grid.Row="1" Grid.Column="1" Style="{StaticResource ActionButton}" Content="✓  Тест связи"/>
        </Grid>
        <TextBlock Grid.Row="2" x:Name="lblFoot" Margin="4,12,4,0" Foreground="#777" FontSize="11"
                   TextAlignment="Center" Text="codeDPI · v1.2.1"/>
    </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$Script:window = [Windows.Markup.XamlReader]::Load($reader)
function Find($name) { $Script:window.FindName($name) }

$dot       = Find 'dot'
$lblStatus = Find 'lblStatus'
$lblDetail = Find 'lblDetail'
$lblFoot   = Find 'lblFoot'
$btnStart  = Find 'btnStart'
$btnStop   = Find 'btnStop'
$btnSettings = Find 'btnSettings'
$btnTest   = Find 'btnTest'

$lblFoot.Text = "codeDPI · v$Script:Version"

# ============================================================================
# Status updater
# ============================================================================
function Set-Dot([string]$color) {
    $brush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($color))
    $dot.Fill = $brush
}

function Update-Status {
    $dpiUp  = Test-WinwsRunning
    $svcUp  = Test-ServiceRunning 'zapret'
    $pacUp  = Test-PacEnabled   $Script:Cfg
    $pacSrv = Test-PacServerRunning
    $warp   = Get-WarpStatus
    $warpUp = $warp.Connected

    $bypass = $dpiUp -or $svcUp
    if ($bypass -and ($Script:Cfg.warp_autostart -eq '1') -and ($Script:Cfg.geo_routing -eq '1')) {
        if ($warpUp -and $pacUp -and $pacSrv) {
            Set-Dot '#2ea043'
            $lblStatus.Text = 'Активно: DPI + WARP + PAC'
        } elseif ($warpUp -and $bypass) {
            Set-Dot '#d29922'
            $lblStatus.Text = 'Частично: DPI + WARP, без PAC'
        } else {
            Set-Dot '#d29922'
            $lblStatus.Text = 'Запускается...'
        }
    } elseif ($bypass) {
        Set-Dot '#2ea043'
        $lblStatus.Text = 'Активно: DPI bypass'
    } else {
        Set-Dot '#666666'
        $lblStatus.Text = 'Выключено'
    }

    # Sub-line: terse details.
    $bits = @()
    if ($dpiUp)  { $bits += 'winws' }
    if ($svcUp)  { $bits += 'service' }
    if ($warpUp) { $bits += 'warp' }
    if ($pacUp -and $pacSrv) { $bits += "pac:$(Get-PacPort $Script:Cfg)" }
    elseif ($pacUp -and -not $pacSrv) { $bits += 'pac:reg(noserver)' }
    elseif ($pacSrv -and -not $pacUp) { $bits += 'pac:srv(notreg)' }
    if (-not $bits) { $bits = @('idle') }
    $lblDetail.Text = ($bits -join '  ·  ')
}

Update-Status
$Script:timer = New-Object System.Windows.Threading.DispatcherTimer
$Script:timer.Interval = [TimeSpan]::FromSeconds(3)
$Script:timer.Add_Tick({ try { Update-Status } catch { } })
$Script:timer.Start()
$Script:window.Add_Closed({ try { if ($Script:timer) { $Script:timer.Stop() } } catch { } })

# ============================================================================
# Action handlers
# ============================================================================
function Show-Toast([string]$message, [string]$title = 'launcher') {
    [System.Windows.MessageBox]::Show($Script:window, $message, $title,
        [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
}

$Script:Busy = $false
function With-Busy([scriptblock]$body) {
    return {
        if ($Script:Busy) { return }
        $Script:Busy = $true
        try {
            $btnStart.IsEnabled = $false
            $btnStop.IsEnabled  = $false
            $btnTest.IsEnabled  = $false
            & $body
        } catch {
            Show-Toast "Ошибка: $_"
        } finally {
            $btnStart.IsEnabled = $true
            $btnStop.IsEnabled  = $true
            $btnTest.IsEnabled  = $true
            try { Update-Status } catch { }
            $Script:Busy = $false
        }
    }.GetNewClosure()
}

$btnStart.Add_Click( (With-Busy {
    $lblDetail.Text = 'Запуск...'
    $r = Start-Combined $Script:Cfg
    if ($r.Bypass -and $r.Errors.Count -eq 0) {
        # silent — status line will reflect the new state.
    } elseif ($r.Bypass) {
        Show-Toast ("Запущено с предупреждениями:`n`n" + ($r.Errors -join "`n"))
    } else {
        Show-Toast ("Не удалось запустить:`n`n" + ($r.Errors -join "`n"))
    }
}) )

$btnStop.Add_Click( (With-Busy {
    $lblDetail.Text = 'Остановка...'
    Stop-Combined $Script:Cfg
}) )

$btnSettings.Add_Click({
    # Open the full GUI in the same console (admin already), then re-read config.
    try {
        $gui = Join-Path $PSScriptRoot 'launcher.gui.ps1'
        $proc = Start-Process -FilePath 'powershell.exe' `
                    -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $gui) `
                    -PassThru
        $proc.WaitForExit()
        $Script:Cfg = Read-Config
        Update-Status
    } catch {
        Show-Toast "Не удалось открыть настройки: $_"
    }
})

$btnTest.Add_Click( (With-Busy {
    $lblDetail.Text = 'Проверка связи (~10 сек)...'
    $t = Test-Connectivity $Script:Cfg
    $lines = @()
    foreach ($k in 'PacServer', 'Warp', 'Dpi', 'Geo') {
        $row = $t[$k]
        $mark = if ($row.Ok) { '[OK]  ' } else { '[FAIL]' }
        $lines += "{0,-6} {1,-9} — {2}" -f $mark, $k, $row.Detail
    }
    Show-Toast ($lines -join "`n") 'Тест соединения'
}) )

# ============================================================================
# Show window
# ============================================================================
[void]$Script:window.ShowDialog()
