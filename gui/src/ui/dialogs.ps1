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
        [array]$Results
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
                    <TextBlock Name="txtSummary" Foreground="#666666" FontSize="11" VerticalAlignment="Center"/>
                    <Button Name="btnOk" Content="OK" HorizontalAlignment="Right" Padding="24,10" Background="#ffffff" Foreground="#000000" BorderThickness="0" Cursor="Hand" FontSize="11" FontWeight="Bold"/>
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
    $btnClose = $dialog.FindName("btnDialogClose")
    $btnOk = $dialog.FindName("btnOk")
    $txtOutput = $dialog.FindName("txtOutput")
    $txtSummary = $dialog.FindName("txtSummary")
    
    $titleBar.Add_MouseLeftButtonDown({ $dialog.DragMove() })
    $btnClose.Add_Click({ $dialog.Close() })
    $btnOk.Add_Click({ $dialog.Close() })
    
    $okCount = @($Results | Where-Object { $_.Status -eq "OK" }).Count
    $warnCount = @($Results | Where-Object { $_.Status -eq "Warning" }).Count
    $errCount = @($Results | Where-Object { $_.Status -eq "Error" }).Count
    $txtSummary.Text = "$okCount OK  |  $warnCount Warnings  |  $errCount Errors"
    
    # Build console-style output
    $output = @()
    foreach ($r in $Results) {
        $prefix = switch ($r.Status) {
            "OK" { "[OK]" }
            "Warning" { "[?]" }
            "Error" { "[X]" }
        }
        $output += "$prefix $($r.Name)"
        if ($r.Message) {
            $output += "    $($r.Message)"
        }
    }
    
    $txtOutput.Text = $output -join "`n"
    
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
