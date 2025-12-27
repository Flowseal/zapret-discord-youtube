# Zapret GUI - Custom Dialog Windows

function Show-CustomDialog {
    param(
        [System.Windows.Window]$Owner,
        [string]$Title,
        [string]$Message,
        [string]$Buttons = "OK"  # OK, YesNo
    )
    
    $dialogXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Dialog" 
        SizeToContent="Height"
        Width="400"
        WindowStartupLocation="CenterScreen"
        WindowStyle="None"
        AllowsTransparency="True"
        Background="Transparent"
        ResizeMode="NoResize">
    <Border Background="#0a0a0a" CornerRadius="12" BorderBrush="#222222" BorderThickness="1">
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="40"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            
            <Border Grid.Row="0" Background="#0a0a0a" CornerRadius="12,12,0,0" Name="DialogTitleBar">
                <Grid>
                    <TextBlock Name="txtTitle" FontSize="12" FontWeight="Bold" Foreground="#ffffff" VerticalAlignment="Center" Margin="16,0,0,0"/>
                    <Button Name="btnDialogClose" Content="X" HorizontalAlignment="Right" Background="Transparent" Foreground="#666666" BorderThickness="0" Width="40" Height="32" Cursor="Hand" FontSize="10"/>
                </Grid>
            </Border>
            
            <Border Grid.Row="1" Padding="20,16">
                <TextBlock Name="txtMessage" Foreground="#cccccc" FontSize="12" TextWrapping="Wrap" LineHeight="20"/>
            </Border>
            
            <Border Grid.Row="2" Background="#050505" CornerRadius="0,0,12,12" Padding="16,12">
                <StackPanel Name="buttonPanel" Orientation="Horizontal" HorizontalAlignment="Right"/>
            </Border>
        </Grid>
    </Border>
</Window>
"@

    [xml]$xaml = $dialogXaml
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $dialog = [Windows.Markup.XamlReader]::Load($reader)
    
    $titleBar = $dialog.FindName("DialogTitleBar")
    $txtTitle = $dialog.FindName("txtTitle")
    $txtMsg = $dialog.FindName("txtMessage")
    $btnClose = $dialog.FindName("btnDialogClose")
    $buttonPanel = $dialog.FindName("buttonPanel")
    
    $txtTitle.Text = $Title
    $txtMsg.Text = $Message
    
    $titleBar.Add_MouseLeftButtonDown({ $dialog.DragMove() })
    $btnClose.Add_Click({ $dialog.Tag = "Cancel"; $dialog.Close() })
    
    if ($Buttons -eq "YesNo") {
        $btnNo = New-Object System.Windows.Controls.Button
        $btnNo.Content = "NO"
        $btnNo.Padding = New-Object System.Windows.Thickness(20, 10, 20, 10)
        $btnNo.Margin = New-Object System.Windows.Thickness(0, 0, 6, 0)
        $btnNo.Background = [System.Windows.Media.Brushes]::Transparent
        $btnNo.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#666666"))
        $btnNo.BorderThickness = New-Object System.Windows.Thickness(1)
        $btnNo.BorderBrush = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#333333"))
        $btnNo.Cursor = [System.Windows.Input.Cursors]::Hand
        $btnNo.FontSize = 11
        $btnNo.FontWeight = [System.Windows.FontWeights]::Bold
        $btnNo.Add_Click({ $dialog.Tag = "No"; $dialog.Close() })
        $buttonPanel.Children.Add($btnNo) | Out-Null
        
        $btnYes = New-Object System.Windows.Controls.Button
        $btnYes.Content = "YES"
        $btnYes.Padding = New-Object System.Windows.Thickness(20, 10, 20, 10)
        $btnYes.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#ffffff"))
        $btnYes.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#000000"))
        $btnYes.BorderThickness = New-Object System.Windows.Thickness(0)
        $btnYes.Cursor = [System.Windows.Input.Cursors]::Hand
        $btnYes.FontSize = 11
        $btnYes.FontWeight = [System.Windows.FontWeights]::Bold
        $btnYes.Add_Click({ $dialog.Tag = "Yes"; $dialog.Close() })
        $buttonPanel.Children.Add($btnYes) | Out-Null
    } else {
        $btnOk = New-Object System.Windows.Controls.Button
        $btnOk.Content = "OK"
        $btnOk.Padding = New-Object System.Windows.Thickness(24, 10, 24, 10)
        $btnOk.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#ffffff"))
        $btnOk.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#000000"))
        $btnOk.BorderThickness = New-Object System.Windows.Thickness(0)
        $btnOk.Cursor = [System.Windows.Input.Cursors]::Hand
        $btnOk.FontSize = 11
        $btnOk.FontWeight = [System.Windows.FontWeights]::Bold
        $btnOk.Add_Click({ $dialog.Tag = "OK"; $dialog.Close() })
        $buttonPanel.Children.Add($btnOk) | Out-Null
    }
    
    if ($Owner) { $dialog.Owner = $Owner }
    $dialog.ShowDialog() | Out-Null
    return $dialog.Tag
}

function Show-DiagnosticsDialog {
    param(
        [System.Windows.Window]$Owner,
        [string]$ServiceBat
    )
    
    $dialogXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Diagnostics" 
        Height="500" Width="550"
        WindowStartupLocation="CenterScreen"
        WindowStyle="None"
        AllowsTransparency="True"
        Background="Transparent"
        ResizeMode="NoResize">
    <Border Background="#0a0a0a" CornerRadius="12" BorderBrush="#222222" BorderThickness="1">
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="40"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            
            <Border Grid.Row="0" Background="#0a0a0a" CornerRadius="12,12,0,0" Name="DialogTitleBar">
                <Grid>
                    <TextBlock Text="DIAGNOSTICS" FontSize="12" FontWeight="Bold" Foreground="#ffffff" VerticalAlignment="Center" Margin="16,0,0,0"/>
                    <Button Name="btnDialogClose" Content="X" HorizontalAlignment="Right" Background="Transparent" Foreground="#666666" BorderThickness="0" Width="40" Height="32" Cursor="Hand" FontSize="10"/>
                </Grid>
            </Border>
            
            <Border Grid.Row="1" Background="#050505" Margin="16,8" CornerRadius="8" Padding="12">
                <ScrollViewer Name="outputScroll" VerticalScrollBarVisibility="Auto">
                    <TextBlock Name="txtOutput" Foreground="#888888" FontFamily="Consolas" FontSize="11" TextWrapping="Wrap"/>
                </ScrollViewer>
            </Border>
            
            <Border Grid.Row="2" Background="#050505" CornerRadius="0,0,12,12" Padding="16,12">
                <Grid>
                    <TextBlock Name="txtStatus" Foreground="#666666" FontSize="11" VerticalAlignment="Center"/>
                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                        <Button Name="btnCopy" Content="COPY" Padding="20,10" Margin="0,0,6,0" Background="Transparent" Foreground="#888888" BorderThickness="1" Cursor="Hand" FontSize="11" FontWeight="Bold"/>
                        <Button Name="btnQuickCheck" Content="QUICK CHECK" Padding="20,10" Margin="0,0,6,0" Background="#ffffff" Foreground="#000000" BorderThickness="0" Cursor="Hand" FontSize="11" FontWeight="Bold"/>
                        <Button Name="btnFullDiag" Content="FULL DIAGNOSTICS" Padding="20,10" Margin="0,0,6,0" Background="Transparent" Foreground="#888888" BorderThickness="1" Cursor="Hand" FontSize="11" FontWeight="Bold"/>
                        <Button Name="btnClose" Content="CLOSE" Padding="20,10" Background="Transparent" Foreground="#666666" BorderThickness="1" Cursor="Hand" FontSize="11" FontWeight="Bold"/>
                    </StackPanel>
                </Grid>
            </Border>
        </Grid>
    </Border>
</Window>
"@

    [xml]$xaml = $dialogXaml
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $dialog = [Windows.Markup.XamlReader]::Load($reader)
    
    $titleBar = $dialog.FindName("DialogTitleBar")
    $btnDialogClose = $dialog.FindName("btnDialogClose")
    $btnCopy = $dialog.FindName("btnCopy")
    $btnQuickCheck = $dialog.FindName("btnQuickCheck")
    $btnFullDiag = $dialog.FindName("btnFullDiag")
    $btnClose = $dialog.FindName("btnClose")
    $txtOutput = $dialog.FindName("txtOutput")
    $txtStatus = $dialog.FindName("txtStatus")
    $outputScroll = $dialog.FindName("outputScroll")
    
    $titleBar.Add_MouseLeftButtonDown({ $dialog.DragMove() })
    $btnDialogClose.Add_Click({ $dialog.Close() })
    $btnClose.Add_Click({ $dialog.Close() })
    $btnClose.BorderBrush = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#333333"))
    $btnFullDiag.BorderBrush = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#333333"))
    $btnCopy.BorderBrush = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#333333"))
    
    # Copy button handler
    $btnCopy.Add_Click({
        $text = $txtOutput.Text
        if ($text -and $text.Trim()) {
            [System.Windows.Clipboard]::SetText($text)
            $txtStatus.Text = "Copied to clipboard"
        } else {
            $txtStatus.Text = "Nothing to copy"
        }
    })
    
    $scriptExists = Test-Path $ServiceBat
    if (-not $scriptExists) {
        $txtOutput.Text = "service.bat not found:`n$ServiceBat"
        $txtStatus.Text = "Error"
        $btnQuickCheck.IsEnabled = $false
        $btnFullDiag.IsEnabled = $false
    } else {
        $txtOutput.Text = "Click QUICK CHECK for basic diagnostics in this window.`nClick FULL DIAGNOSTICS to open interactive diagnostics in CMD."
        $txtStatus.Text = "Ready"
    }
    
    # Quick check (non-interactive checks)
    $btnQuickCheck.Add_Click({
        $txtOutput.Text = "Running quick diagnostics...`n"
        $txtStatus.Text = "Checking..."
        $btnQuickCheck.IsEnabled = $false
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Background, [Action]{})
        
        $output = @()
        
        # BFE check
        $bfe = sc.exe query BFE 2>&1
        if (($bfe -join "`n") -match "RUNNING") {
            $output += "[OK] Base Filtering Engine check passed"
        } else {
            $output += "[X] Base Filtering Engine is not running"
        }
        
        # Proxy check
        $proxyEnabled = (Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -Name ProxyEnable -ErrorAction SilentlyContinue).ProxyEnable
        if ($proxyEnabled -eq 1) {
            $proxyServer = (Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -Name ProxyServer -ErrorAction SilentlyContinue).ProxyServer
            $output += "[?] System proxy is enabled: $proxyServer"
        } else {
            $output += "[OK] Proxy check passed"
        }
        
        # TCP timestamps
        $tcp = netsh interface tcp show global 2>&1
        if (($tcp -join "`n") -match "timestamps.*enabled" -or ($tcp -join "`n") -match "Timestamps.*enabled") {
            $output += "[OK] TCP timestamps check passed"
        } else {
            $output += "[?] TCP timestamps disabled, enabling..."
            $null = netsh interface tcp set global timestamps=enabled 2>&1
        }
        
        # Adguard
        $adguard = Get-Process -Name "AdguardSvc" -ErrorAction SilentlyContinue
        if ($adguard) {
            $output += "[X] Adguard process found - may cause problems"
        } else {
            $output += "[OK] Adguard check passed"
        }
        
        # Killer services
        $sc = sc.exe query 2>&1
        if (($sc -join "`n") -match "Killer") {
            $output += "[X] Killer services found - conflicts with zapret"
        } else {
            $output += "[OK] Killer check passed"
        }
        
        # Intel Connectivity
        if (($sc -join "`n") -match "Intel.*Connectivity") {
            $output += "[X] Intel Connectivity found - conflicts with zapret"
        } else {
            $output += "[OK] Intel Connectivity check passed"
        }
        
        # Check Point
        if (($sc -join "`n") -match "TracSrvWrapper|EPWD") {
            $output += "[X] Check Point found - conflicts with zapret"
        } else {
            $output += "[OK] Check Point check passed"
        }
        
        # SmartByte
        if (($sc -join "`n") -match "SmartByte") {
            $output += "[X] SmartByte found - conflicts with zapret"
        } else {
            $output += "[OK] SmartByte check passed"
        }
        
        # VPN
        if (($sc -join "`n") -match "VPN") {
            $output += "[?] VPN services found - may conflict with zapret"
        } else {
            $output += "[OK] VPN check passed"
        }
        
        # WinDivert driver
        $binDir = Join-Path $script:RootDir "bin"
        $sysFiles = Get-ChildItem -Path $binDir -Filter "*.sys" -ErrorAction SilentlyContinue
        if ($sysFiles -and $sysFiles.Count -gt 0) {
            $output += "[OK] WinDivert driver found"
        } else {
            $output += "[X] WinDivert64.sys not found in bin folder"
        }
        
        # Conflicting bypasses
        $conflicts = @("GoodbyeDPI", "discordfix_zapret", "winws1", "winws2")
        $found = @()
        foreach ($svc in $conflicts) {
            $out = sc.exe query $svc 2>&1
            if (($out -join "`n") -notmatch "FAILED 1060") {
                $found += $svc
            }
        }
        if ($found.Count -gt 0) {
            $output += "[X] Conflicting bypasses: $($found -join ', ')"
        } else {
            $output += "[OK] No conflicting bypasses"
        }
        
        $output += ""
        $hasErrors = ($output -join "`n") -match "\[X\]"
        $hasWarnings = ($output -join "`n") -match "\[\?\]"
        if ($hasErrors) {
            $output += "Errors found. Use FULL DIAGNOSTICS for interactive fixes."
            $txtStatus.Text = "Errors found"
        } elseif ($hasWarnings) {
            $output += "Warnings found. Check details above."
            $txtStatus.Text = "Warnings"
        } else {
            $output += "All checks passed!"
            $txtStatus.Text = "All OK"
        }
        
        $txtOutput.Text = $output -join "`n"
        $btnQuickCheck.IsEnabled = $true
        $outputScroll.ScrollToEnd()
    })
    
    # Full diagnostics in separate CMD window
    $btnFullDiag.Add_Click({
        $txtStatus.Text = "Launching..."
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Background, [Action]{})
        
        try {
            # Create a temp batch file that runs diagnostics directly
            $tempBat = Join-Path $env:TEMP "zapret_diag_temp.bat"
            $batContent = @"
@echo off
cd /d "$script:RootDir"
call service.bat admin
goto service_diagnostics
"@
            # Actually just run service.bat and let user choose option 4
            Start-Process "cmd.exe" -ArgumentList "/c `"$ServiceBat`"" -WorkingDirectory $script:RootDir -Verb RunAs
            $txtOutput.Text += "`n`n[INFO] Full diagnostics launched in CMD window.`nSelect option 4 (Run Diagnostics) from the menu."
            $txtStatus.Text = "Launched"
        } catch {
            $txtOutput.Text += "`n`n[ERROR] Failed to launch: $($_.Exception.Message)"
            $txtStatus.Text = "Error"
        }
        $outputScroll.ScrollToEnd()
    })
    
    if ($Owner) { $dialog.Owner = $Owner }
    $dialog.ShowDialog() | Out-Null
}

function Show-TestsDialog {
    param(
        [System.Windows.Window]$Owner,
        [string]$TestScript
    )
    
    $dialogXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Tests" 
        Height="500" Width="550"
        WindowStartupLocation="CenterScreen"
        WindowStyle="None"
        AllowsTransparency="True"
        Background="Transparent"
        ResizeMode="NoResize">
    <Border Background="#0a0a0a" CornerRadius="12" BorderBrush="#222222" BorderThickness="1">
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="40"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            
            <Border Grid.Row="0" Background="#0a0a0a" CornerRadius="12,12,0,0" Name="DialogTitleBar">
                <Grid>
                    <TextBlock Text="PRE-FLIGHT CHECK" FontSize="12" FontWeight="Bold" Foreground="#ffffff" VerticalAlignment="Center" Margin="16,0,0,0"/>
                    <Button Name="btnDialogClose" Content="X" HorizontalAlignment="Right" Background="Transparent" Foreground="#666666" BorderThickness="0" Width="40" Height="32" Cursor="Hand" FontSize="10"/>
                </Grid>
            </Border>
            
            <Border Grid.Row="1" Background="#050505" Margin="16,8" CornerRadius="8" Padding="12">
                <ScrollViewer Name="outputScroll" VerticalScrollBarVisibility="Auto">
                    <TextBlock Name="txtOutput" Foreground="#888888" FontFamily="Consolas" FontSize="11" TextWrapping="Wrap"/>
                </ScrollViewer>
            </Border>
            
            <Border Grid.Row="2" Background="#050505" CornerRadius="0,0,12,12" Padding="16,12">
                <Grid>
                    <TextBlock Name="txtStatus" Foreground="#666666" FontSize="11" VerticalAlignment="Center"/>
                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                        <Button Name="btnCopy" Content="COPY" Padding="20,10" Margin="0,0,6,0" Background="Transparent" Foreground="#888888" BorderThickness="1" Cursor="Hand" FontSize="11" FontWeight="Bold"/>
                        <Button Name="btnCheck" Content="CHECK" Padding="20,10" Margin="0,0,6,0" Background="#ffffff" Foreground="#000000" BorderThickness="0" Cursor="Hand" FontSize="11" FontWeight="Bold"/>
                        <Button Name="btnRunFull" Content="RUN FULL TEST" Padding="20,10" Margin="0,0,6,0" Background="Transparent" Foreground="#888888" BorderThickness="1" Cursor="Hand" FontSize="11" FontWeight="Bold"/>
                        <Button Name="btnClose" Content="CLOSE" Padding="20,10" Background="Transparent" Foreground="#666666" BorderThickness="1" Cursor="Hand" FontSize="11" FontWeight="Bold"/>
                    </StackPanel>
                </Grid>
            </Border>
        </Grid>
    </Border>
</Window>
"@

    [xml]$xaml = $dialogXaml
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $dialog = [Windows.Markup.XamlReader]::Load($reader)
    
    $titleBar = $dialog.FindName("DialogTitleBar")
    $btnDialogClose = $dialog.FindName("btnDialogClose")
    $btnCopy = $dialog.FindName("btnCopy")
    $btnCheck = $dialog.FindName("btnCheck")
    $btnRunFull = $dialog.FindName("btnRunFull")
    $btnClose = $dialog.FindName("btnClose")
    $txtOutput = $dialog.FindName("txtOutput")
    $txtStatus = $dialog.FindName("txtStatus")
    $outputScroll = $dialog.FindName("outputScroll")
    
    $titleBar.Add_MouseLeftButtonDown({ $dialog.DragMove() })
    $btnDialogClose.Add_Click({ $dialog.Close() })
    $btnClose.Add_Click({ $dialog.Close() })
    $btnClose.BorderBrush = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#333333"))
    $btnRunFull.BorderBrush = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#333333"))
    $btnCopy.BorderBrush = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString("#333333"))
    
    # Copy button handler
    $btnCopy.Add_Click({
        $text = $txtOutput.Text
        if ($text -and $text.Trim()) {
            [System.Windows.Clipboard]::SetText($text)
            $txtStatus.Text = "Copied to clipboard"
        } else {
            $txtStatus.Text = "Nothing to copy"
        }
    })
    
    $scriptExists = Test-Path $TestScript
    if (-not $scriptExists) {
        $txtOutput.Text = "Test script not found:`n$TestScript"
        $txtStatus.Text = "Error"
        $btnCheck.IsEnabled = $false
        $btnRunFull.IsEnabled = $false
    } else {
        $txtOutput.Text = "Click CHECK to run pre-flight diagnostics.`nClick RUN FULL TEST to open interactive test in PowerShell."
        $txtStatus.Text = "Ready"
    }
    
    # Pre-flight check (non-interactive checks from test script)
    $btnCheck.Add_Click({
        $txtOutput.Text = "Running pre-flight checks...`n"
        $txtStatus.Text = "Checking..."
        $btnCheck.IsEnabled = $false
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Background, [Action]{})
        
        $output = @()
        
        # Admin check
        $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if ($isAdmin) {
            $output += "[OK] Administrator rights detected"
        } else {
            $output += "[ERROR] Run as Administrator to execute tests"
        }
        
        # curl check
        if (Get-Command "curl.exe" -ErrorAction SilentlyContinue) {
            $output += "[OK] curl.exe found"
        } else {
            $output += "[ERROR] curl.exe not found"
        }
        
        # ipset status
        $listsDir = Join-Path $script:RootDir "lists"
        $listFile = Join-Path $listsDir "ipset-all.txt"
        $ipsetStatus = "none"
        if (Test-Path $listFile) {
            $lineCount = (Get-Content $listFile -ErrorAction SilentlyContinue | Measure-Object -Line).Lines
            if ($lineCount -eq 0) { $ipsetStatus = "any" }
            else {
                $hasDummy = Get-Content $listFile -ErrorAction SilentlyContinue | Select-String -Pattern "203\.0\.113\.113/32" -Quiet
                if ($hasDummy) { $ipsetStatus = "none" } else { $ipsetStatus = "loaded" }
            }
        }
        $output += "[INFO] Current ipset status: $ipsetStatus"
        
        if ($ipsetStatus -ne "any") {
            $output += "[WARNING] Ipset will be switched to 'any' for accurate DPI tests."
        }
        
        # zapret service check
        $zapretSvc = Get-Service -Name "zapret" -ErrorAction SilentlyContinue
        if ($zapretSvc) {
            $output += ""
            $output += "[WARNING] Windows service 'zapret' is installed"
            $output += "          For FULL TEST: remove service first (tests run own configs)"
            $output += "          For normal use: this is OK, service is working"
        } else {
            $output += "[OK] No zapret service (ready for full test)"
        }
        
        # winws process check
        $winws = Get-Process -Name "winws" -ErrorAction SilentlyContinue
        if ($winws) {
            $output += "[WARNING] winws process is running (will be stopped for tests)"
        }
        
        # Check for general*.bat files
        $batFiles = Get-ChildItem -Path $script:RootDir -Filter "general*.bat" -ErrorAction SilentlyContinue
        if ($batFiles -and $batFiles.Count -gt 0) {
            $output += "[OK] Found $($batFiles.Count) strategy configs (general*.bat)"
        } else {
            $output += "[ERROR] No general*.bat files found"
        }
        
        $output += ""
        $hasErrors = ($output -join "`n") -match "\[ERROR\]"
        $hasWarnings = ($output -join "`n") -match "\[WARNING\]"
        if ($hasErrors) {
            $output += "Fix errors above before running tests."
            $txtStatus.Text = "Errors found"
        } elseif ($hasWarnings) {
            $output += "Warnings found. Full test may require service removal."
            $txtStatus.Text = "Ready (with warnings)"
        } else {
            $output += "All checks passed! Ready for full test."
            $txtStatus.Text = "Ready for test"
        }
        
        $txtOutput.Text = $output -join "`n"
        $btnCheck.IsEnabled = $true
        $outputScroll.ScrollToEnd()
    })
    
    # Run full interactive test in separate window
    $btnRunFull.Add_Click({
        $txtStatus.Text = "Launching..."
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Background, [Action]{})
        
        try {
            Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -NoExit -File `"$TestScript`"" -WorkingDirectory (Split-Path $TestScript -Parent)
            $txtOutput.Text += "`n`n[INFO] Full test launched in separate window."
            $txtStatus.Text = "Launched"
        } catch {
            $txtOutput.Text += "`n`n[ERROR] Failed to launch: $($_.Exception.Message)"
            $txtStatus.Text = "Error"
        }
        $outputScroll.ScrollToEnd()
    })
    
    if ($Owner) { $dialog.Owner = $Owner }
    $dialog.ShowDialog() | Out-Null
}
