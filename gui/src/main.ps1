# Zapret GUI - Main Entry Point
# Requires PowerShell 5.1+ and Windows 10/11

#region Admin Check
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$($MyInvocation.MyCommand.Path)`"" -Verb RunAs
    exit
}
#endregion

#region Load Modules
$scriptRoot = $PSScriptRoot

. "$scriptRoot\config.ps1"
. "$scriptRoot\services.ps1"
. "$scriptRoot\settings.ps1"
. "$scriptRoot\diagnostics.ps1"
. "$scriptRoot\updates.ps1"
. "$scriptRoot\ui\theme.ps1"
. "$scriptRoot\ui\xaml.ps1"
. "$scriptRoot\ui\dialogs.ps1"
#endregion

#region WPF Setup
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
#endregion

#region Create Window
[xml]$xaml = Get-MainWindowXaml -Version $script:Config.Version
$reader = New-Object System.Xml.XmlNodeReader $xaml
$script:window = [Windows.Markup.XamlReader]::Load($reader)
$window = $script:window

# Get controls
$titleBar = $window.FindName("TitleBar")
$btnMin = $window.FindName("btnMin")
$btnClose = $window.FindName("btnClose")

$txtZapret = $window.FindName("txtZapret")
$txtWinDivert = $window.FindName("txtWinDivert")
$txtProcess = $window.FindName("txtProcess")
$txtStrategy = $window.FindName("txtStrategy")

$cmbStrategy = $window.FindName("cmbStrategy")
$btnInstall = $window.FindName("btnInstall")
$btnRemove = $window.FindName("btnRemove")
$btnDiag = $window.FindName("btnDiag")
$btnTests = $window.FindName("btnTests")
$btnUpdate = $window.FindName("btnUpdate")
$btnRefresh = $window.FindName("btnRefresh")

$btnGameFilter = $window.FindName("btnGameFilter")
$btnAutoUpdate = $window.FindName("btnAutoUpdate")
$btnIPset = $window.FindName("btnIPset")
$txtHint = $window.FindName("txtHint")

$txtLog = $window.FindName("txtLog")
$logScroll = $window.FindName("logScroll")
$btnClear = $window.FindName("btnClear")

$linkGH = $window.FindName("linkGH")
#endregion

#region Helper Functions
function Write-Log {
    param([string]$Message)
    $time = Get-Date -Format "HH:mm:ss"
    $txtLog.Text = "[$time] $Message`r`n" + $txtLog.Text
    $logScroll.ScrollToTop()
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Background, [Action]{})
}

function Update-Status {
    $zapret = Get-ZapretStatus
    $txtZapret.Text = Format-StatusText $zapret
    $txtZapret.Foreground = Get-StatusColor $zapret
    
    $wd = Get-WinDivertStatus
    $txtWinDivert.Text = Format-StatusText $wd
    $txtWinDivert.Foreground = Get-StatusColor $wd
    
    $proc = Get-BypassProcessStatus
    $txtProcess.Text = Format-StatusText $proc
    $txtProcess.Foreground = Get-StatusColor $proc
    
    $strategy = Get-InstalledStrategy
    $txtStrategy.Text = if ($strategy) { $strategy } else { "None" }
}

function Update-StrategyList {
    $cmbStrategy.Items.Clear()
    $strategies = Get-AvailableStrategies
    foreach ($s in $strategies) {
        $cmbStrategy.Items.Add($s) | Out-Null
    }
    if ($cmbStrategy.Items.Count -gt 0) {
        $cmbStrategy.SelectedIndex = 0
    }
}

function Update-Settings {
    $btnGameFilter.Content = if (Get-GameFilterStatus) { "ON" } else { "OFF" }
    $btnAutoUpdate.Content = if (Get-AutoUpdateStatus) { "ON" } else { "OFF" }
    $btnIPset.Content = Get-IPsetMode
}
#endregion

#region Event Handlers
# Window controls
$titleBar.Add_MouseLeftButtonDown({ $script:window.DragMove() })
$btnMin.Add_Click({ $script:window.WindowState = 'Minimized' })
$btnClose.Add_Click({ $script:window.Close() })

# GitHub link
$linkGH.Add_RequestNavigate({
    Start-Process $script:Config.DesignerUrl
    $_.Handled = $true
})

# Refresh
$btnRefresh.Add_Click({
    Write-Log "Refreshing..."
    Update-Status
    Update-Settings
    Write-Log "Done"
})

# Install
$btnInstall.Add_Click({
    $strategy = $cmbStrategy.SelectedItem
    if ($strategy) {
        Write-Log "Installing: $strategy"
        $btnInstall.IsEnabled = $false
        $result = Install-ZapretService -StrategyFile $strategy
        if ($result.Success) {
            Write-Log $result.Message
        } else {
            Write-Log "ERROR: $($result.Message)"
        }
        $btnInstall.IsEnabled = $true
        Update-Status
    } else {
        Write-Log "Select a strategy first"
    }
})

# Remove
$btnRemove.Add_Click({
    Write-Log "Removing services..."
    $btnRemove.IsEnabled = $false
    $result = Remove-ZapretServices
    foreach ($msg in $result.Messages) {
        Write-Log $msg
    }
    $btnRemove.IsEnabled = $true
    Update-Status
})

# Diagnostics
$btnDiag.Add_Click({
    Write-Log "Running diagnostics..."
    $results = Invoke-Diagnostics
    $ok = @($results | Where-Object { $_.Status -eq "OK" }).Count
    $warn = @($results | Where-Object { $_.Status -eq "Warning" }).Count
    $err = @($results | Where-Object { $_.Status -eq "Error" }).Count
    Write-Log "Results: $ok OK, $warn warnings, $err errors"
    
    Show-DiagnosticsDialog -Owner $script:window -Results $results
})

# Tests
$btnTests.Add_Click({
    Write-Log "Opening tests..."
    $testScript = Join-Path $script:RootDir "utils\test zapret.ps1"
    Show-TestsDialog -Owner $script:window -TestScript $testScript
})

# Updates
$btnUpdate.Add_Click({
    Write-Log "Checking updates..."
    $info = Test-NewVersionAvailable
    if ($info.Error) {
        Write-Log "ERROR: $($info.Error)"
        Show-CustomDialog -Owner $script:window -Title "Error" -Message "Failed to check updates:`n$($info.Error)"
    } elseif ($info.Available) {
        Write-Log "New version: $($info.LatestVersion)"
        $result = Show-CustomDialog -Owner $script:window -Title "Update Available" -Message "New version $($info.LatestVersion) available!`n`nCurrent: $($info.CurrentVersion)`n`nDownload now?" -Buttons "YesNo"
        if ($result -eq "Yes") {
            Start-Process $info.DownloadUrl
        }
    } else {
        Write-Log "You have the latest version"
        Show-CustomDialog -Owner $script:window -Title "Up to Date" -Message "You have the latest version: $($info.CurrentVersion)"
    }
})

# Game Filter
$btnGameFilter.Add_Click({
    $current = Get-GameFilterStatus
    Set-GameFilter -Enabled (-not $current)
    $btnGameFilter.Content = if (-not $current) { "ON" } else { "OFF" }
    Write-Log "Game Filter: $(if (-not $current) { 'enabled' } else { 'disabled' })"
    $txtHint.Visibility = "Visible"
})

# Auto Update
$btnAutoUpdate.Add_Click({
    $current = Get-AutoUpdateStatus
    Set-AutoUpdate -Enabled (-not $current)
    $btnAutoUpdate.Content = if (-not $current) { "ON" } else { "OFF" }
    Write-Log "Auto Updates: $(if (-not $current) { 'enabled' } else { 'disabled' })"
})

# IPset Mode
$btnIPset.Add_Click({
    $next = Get-NextIPsetMode
    $result = Set-IPsetMode -Mode $next
    if ($result) {
        $btnIPset.Content = $next
        Write-Log "IPset Mode: $next"
        $txtHint.Visibility = "Visible"
    } else {
        Write-Log "ERROR: Cannot change IPset mode"
    }
})

# Clear Log
$btnClear.Add_Click({
    $txtLog.Text = ""
})
#endregion

#region Initialize
Write-Log "Zapret GUI v$($script:Config.Version) started"
Update-StrategyList
Update-Status
Update-Settings
#endregion

# Show window
$window.ShowDialog() | Out-Null
