#requires -Version 5.1
param([string]$RootPath)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

$rootCandidate = $RootPath
if ([string]::IsNullOrWhiteSpace($rootCandidate)) { $rootCandidate = Join-Path $PSScriptRoot '..' }
$script:Root = [System.IO.Path]::GetFullPath($rootCandidate)
$script:ExpectedWinws = [System.IO.Path]::GetFullPath((Join-Path $script:Root 'bin\winws.exe'))
$script:SelectedStrategy = $null
$script:Strategies = @()
$script:SyncingStrategy = $false
$script:LaunchProcess = $null
$script:LaunchLogPath = $null
$script:AutoPickWorker = $null
$script:AutoPickPendingClose = $false
$script:AutoPickButtons = @()
$script:AutoPickProgress = $null
$script:AutoPickResultLabel = $null
$script:PowerButton = $null
$script:PowerButtonState = 'idle'
$script:PowerButtonHover = $false
$script:LastAutoPickLogMessage = ''
$script:EventLog = $null
$script:ContentHost = $null
$script:LastRunningState = $null
$script:Status = $null
$script:Pages = @{}
$script:NavButtons = @{}

$script:Palette = @{
    Background = [System.Drawing.ColorTranslator]::FromHtml('#111215')
    Sidebar    = [System.Drawing.ColorTranslator]::FromHtml('#15171B')
    Card       = [System.Drawing.ColorTranslator]::FromHtml('#191B20')
    CardAlt    = [System.Drawing.ColorTranslator]::FromHtml('#22252B')
    Border     = [System.Drawing.ColorTranslator]::FromHtml('#30343B')
    Text       = [System.Drawing.ColorTranslator]::FromHtml('#F1F2F4')
    Muted      = [System.Drawing.ColorTranslator]::FromHtml('#90959E')
    Accent     = [System.Drawing.ColorTranslator]::FromHtml('#8B6CFF')
    AccentHover= [System.Drawing.ColorTranslator]::FromHtml('#9A82FF')
    Blue       = [System.Drawing.ColorTranslator]::FromHtml('#3269B4')
    BlueSoft   = [System.Drawing.ColorTranslator]::FromHtml('#1A2B46')
    Green      = [System.Drawing.ColorTranslator]::FromHtml('#22D075')
    Red        = [System.Drawing.ColorTranslator]::FromHtml('#FF6675')
    Amber      = [System.Drawing.ColorTranslator]::FromHtml('#E6B857')
}

function Test-Administrator {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [System.Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Administrator)) {
    try {
        $powerShellExe = Join-Path $PSHOME 'powershell.exe'
        $argumentLine = '-NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "' + $PSCommandPath + '"'
        Start-Process -FilePath $powerShellExe -ArgumentList $argumentLine -WorkingDirectory $script:Root -Verb RunAs
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            'Для запуска и остановки winws.exe нужны права администратора. Подтвердите запрос UAC и запустите приложение ещё раз.',
            'Zapret Manager',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    }
    exit
}

function Show-Notice {
    param(
        [string]$Text,
        [string]$Title = 'Zapret Manager',
        [System.Windows.Forms.MessageBoxIcon]$Icon = [System.Windows.Forms.MessageBoxIcon]::Information
    )
    [System.Windows.Forms.MessageBox]::Show(
        $Text,
        $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        $Icon
    ) | Out-Null
}

function Get-Color {
    param([string]$Name)
    if ($script:Palette.ContainsKey($Name)) { return $script:Palette[$Name] }
    return [System.Drawing.ColorTranslator]::FromHtml($Name)
}

function New-UiRoundedPath {
    param([int]$Width, [int]$Height, [int]$Radius = 12)
    $width = [Math]::Max(2, $Width)
    $height = [Math]::Max(2, $Height)
    $diameter = [Math]::Min(($Radius * 2), [Math]::Min($width, $height))
    $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
    if ($diameter -lt 2) {
        $path.AddRectangle([System.Drawing.Rectangle]::new(0, 0, $width, $height))
        return $path
    }
    $path.AddArc(0, 0, $diameter, $diameter, 180, 90)
    $path.AddArc(($width - $diameter), 0, $diameter, $diameter, 270, 90)
    $path.AddArc(($width - $diameter), ($height - $diameter), $diameter, $diameter, 0, 90)
    $path.AddArc(0, ($height - $diameter), $diameter, $diameter, 90, 90)
    $path.CloseFigure()
    return $path
}

function Set-UiRoundedRegion {
    param([object]$Control, [int]$Radius = 12)
    if (-not $Control -or $Control.Width -lt 2 -or $Control.Height -lt 2) { return }
    $path = New-UiRoundedPath -Width $Control.Width -Height $Control.Height -Radius $Radius
    $region = [System.Drawing.Region]::new($path)
    $oldRegion = $Control.Region
    $Control.Region = $region
    if ($oldRegion) { $oldRegion.Dispose() }
    $path.Dispose()
}

function Add-UiPanel {
    param(
        [object]$Parent,
        [int]$X,
        [int]$Y,
        [int]$Width,
        [int]$Height,
        [string]$Color = 'Card',
        [switch]$Border
    )
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Location = [System.Drawing.Point]::new($X, $Y)
    $panel.Size = [System.Drawing.Size]::new($Width, $Height)
    $panel.BackColor = Get-Color $Color
    if ($Border) {
        $panel.BorderStyle = [System.Windows.Forms.BorderStyle]::None
        Set-UiRoundedRegion -Control $panel -Radius 12
        $panel.Add_SizeChanged({
            param($sender, $eventArgs)
            Set-UiRoundedRegion -Control $sender -Radius 12
        })
        $panel.Add_Paint({
            param($sender, $eventArgs)
            $eventArgs.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $path = New-UiRoundedPath -Width ([Math]::Max(2, $sender.ClientSize.Width - 1)) -Height ([Math]::Max(2, $sender.ClientSize.Height - 1)) -Radius 12
            $pen = [System.Drawing.Pen]::new($script:Palette.Border, 1)
            $eventArgs.Graphics.DrawPath($pen, $path)
            $pen.Dispose()
            $path.Dispose()
        })
    }
    [void]$Parent.Controls.Add($panel)
    return $panel
}

function Add-UiLabel {
    param(
        [object]$Parent,
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$Width,
        [int]$Height,
        [string]$Color = 'Text',
        [float]$Size = 10,
        [switch]$Bold,
        [System.Drawing.ContentAlignment]$Align = [System.Drawing.ContentAlignment]::MiddleLeft
    )
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = [System.Drawing.Point]::new($X, $Y)
    $label.Size = [System.Drawing.Size]::new($Width, $Height)
    $label.ForeColor = Get-Color $Color
    $label.BackColor = [System.Drawing.Color]::Transparent
    $label.TextAlign = $Align
    $label.AutoEllipsis = $true
    $style = [System.Drawing.FontStyle]::Regular
    if ($Bold) { $style = [System.Drawing.FontStyle]::Bold }
    $label.Font = [System.Drawing.Font]::new('Segoe UI', $Size, $style)
    [void]$Parent.Controls.Add($label)
    return $label
}

function Add-UiButton {
    param(
        [object]$Parent,
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$Width,
        [int]$Height,
        [string]$Variant = 'secondary'
    )
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Location = [System.Drawing.Point]::new($X, $Y)
    $button.Size = [System.Drawing.Size]::new($Width, $Height)
    $button.Font = [System.Drawing.Font]::new('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.FlatAppearance.BorderSize = 0
    $button.UseVisualStyleBackColor = $false
    $button.Cursor = [System.Windows.Forms.Cursors]::Hand
    $button.Add_SizeChanged({
        param($sender, $eventArgs)
        Set-UiRoundedRegion -Control $sender -Radius 8
    })
    if ($Variant -eq 'primary') {
        $button.BackColor = $script:Palette.Accent
        $button.ForeColor = [System.Drawing.Color]::White
        $button.FlatAppearance.MouseOverBackColor = $script:Palette.AccentHover
        $button.FlatAppearance.MouseDownBackColor = $script:Palette.AccentHover
    } elseif ($Variant -eq 'danger') {
        $button.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#332127')
        $button.ForeColor = $script:Palette.Red
        $button.FlatAppearance.MouseOverBackColor = [System.Drawing.ColorTranslator]::FromHtml('#432931')
    } elseif ($Variant -eq 'nav') {
        $button.BackColor = $script:Palette.Sidebar
        $button.ForeColor = $script:Palette.Muted
        $button.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
        $button.Padding = [System.Windows.Forms.Padding]::new(8, 0, 8, 0)
        $button.FlatAppearance.MouseOverBackColor = $script:Palette.CardAlt
    } else {
        $button.BackColor = $script:Palette.CardAlt
        $button.ForeColor = $script:Palette.Text
        $button.FlatAppearance.BorderSize = 1
        $button.FlatAppearance.BorderColor = $script:Palette.Border
        $button.FlatAppearance.MouseOverBackColor = [System.Drawing.ColorTranslator]::FromHtml('#292D34')
    }
    Set-UiRoundedRegion -Control $button -Radius 8
    [void]$Parent.Controls.Add($button)
    return $button
}

function Add-UiComboBox {
    param([object]$Parent, [int]$X, [int]$Y, [int]$Width, [int]$Height = 34)
    $combo = New-Object System.Windows.Forms.ComboBox
    $combo.Location = [System.Drawing.Point]::new($X, $Y)
    $combo.Size = [System.Drawing.Size]::new($Width, $Height)
    $combo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $combo.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $combo.BackColor = $script:Palette.CardAlt
    $combo.ForeColor = $script:Palette.Text
    $combo.Font = [System.Drawing.Font]::new('Segoe UI', 9.5, [System.Drawing.FontStyle]::Regular)
    [void]$Parent.Controls.Add($combo)
    return $combo
}

function Add-UiTextBox {
    param([object]$Parent, [int]$X, [int]$Y, [int]$Width, [int]$Height = 32)
    $box = New-Object System.Windows.Forms.TextBox
    $box.Location = [System.Drawing.Point]::new($X, $Y)
    $box.Size = [System.Drawing.Size]::new($Width, $Height)
    $box.BackColor = $script:Palette.CardAlt
    $box.ForeColor = $script:Palette.Text
    $box.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $box.Font = [System.Drawing.Font]::new('Segoe UI', 9.5, [System.Drawing.FontStyle]::Regular)
    [void]$Parent.Controls.Add($box)
    return $box
}

function New-PowerButton {
    param([object]$Parent, [int]$X, [int]$Y, [int]$Diameter = 220)
    $control = New-Object System.Windows.Forms.Panel
    $control.Location = [System.Drawing.Point]::new($X, $Y)
    $control.Size = [System.Drawing.Size]::new($Diameter, $Diameter)
    $control.BackColor = $script:Palette.Background
    Set-UiRoundedRegion -Control $control -Radius ([int]($Diameter / 2))
    $control.Cursor = [System.Windows.Forms.Cursors]::Hand
    $control.TabStop = $true
    $control.AccessibleName = 'Запустить или остановить Zapret'
    $control.AccessibleRole = [System.Windows.Forms.AccessibleRole]::PushButton
    $control.Add_SizeChanged({
        param($sender, $eventArgs)
        Set-UiRoundedRegion -Control $sender -Radius ([int]($sender.Width / 2))
    })
    $control.Add_Paint({
        param($sender, $eventArgs)
        $graphics = $eventArgs.Graphics
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $width = $sender.ClientSize.Width
        $height = $sender.ClientSize.Height
        $size = [Math]::Min($width, $height)
        $outerRect = [System.Drawing.RectangleF]::new(8, 8, ($size - 16), ($size - 16))
        $outerColor = [System.Drawing.ColorTranslator]::FromHtml('#172747')
        if ($script:PowerButtonHover) { $outerColor = [System.Drawing.ColorTranslator]::FromHtml('#1D3157') }
        $outerBrush = [System.Drawing.SolidBrush]::new($outerColor)
        $graphics.FillEllipse($outerBrush, $outerRect)
        $outerBrush.Dispose()
        $ringPen = [System.Drawing.Pen]::new($script:Palette.Blue, 2)
        $graphics.DrawEllipse($ringPen, $outerRect)
        $ringPen.Dispose()

        $innerRect = [System.Drawing.RectangleF]::new(16, 16, ($size - 32), ($size - 32))
        $innerBrush = [System.Drawing.SolidBrush]::new([System.Drawing.ColorTranslator]::FromHtml('#15151D'))
        $graphics.FillEllipse($innerBrush, $innerRect)
        $innerBrush.Dispose()
        $innerPen = [System.Drawing.Pen]::new([System.Drawing.ColorTranslator]::FromHtml('#252630'), 1)
        $graphics.DrawEllipse($innerPen, $innerRect)
        $innerPen.Dispose()

        $centerX = [single]($size / 2)
        $iconY = [single]($size * 0.38)
        $iconColor = $script:Palette.Accent
        if ($script:PowerButtonState -eq 'active') { $iconColor = $script:Palette.Green }
        elseif ($script:PowerButtonState -eq 'launch') { $iconColor = $script:Palette.Amber }
        $iconPen = [System.Drawing.Pen]::new($iconColor, 4)
        $iconPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
        $iconPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
        $iconRadius = [single]($size * 0.13)
        $graphics.DrawArc($iconPen, ($centerX - $iconRadius), ($iconY - $iconRadius), ($iconRadius * 2), ($iconRadius * 2), 315, 270)
        $graphics.DrawLine($iconPen, $centerX, ($iconY - ($iconRadius * 1.35)), $centerX, ($iconY + 1))
        $iconPen.Dispose()

        $caption = 'ЗАПУСТИТЬ'
        $hint = 'Нажмите, чтобы включить'
        if ($script:PowerButtonState -eq 'active') { $caption = 'ОСТАНОВИТЬ'; $hint = 'Zapret работает' }
        elseif ($script:PowerButtonState -eq 'launch') { $caption = 'ОТМЕНИТЬ'; $hint = 'Запуск выполняется' }
        $format = [System.Drawing.StringFormat]::new()
        $format.Alignment = [System.Drawing.StringAlignment]::Center
        $format.LineAlignment = [System.Drawing.StringAlignment]::Center
        $captionFont = [System.Drawing.Font]::new('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
        $hintFont = [System.Drawing.Font]::new('Segoe UI', 8, [System.Drawing.FontStyle]::Regular)
        $captionBrush = [System.Drawing.SolidBrush]::new($script:Palette.Text)
        $hintBrush = [System.Drawing.SolidBrush]::new($script:Palette.Muted)
        $graphics.DrawString($caption, $captionFont, $captionBrush, [System.Drawing.RectangleF]::new(16, ($size * 0.60), ($size - 32), 22), $format)
        $graphics.DrawString($hint, $hintFont, $hintBrush, [System.Drawing.RectangleF]::new(18, ($size * 0.72), ($size - 36), 22), $format)
        $captionFont.Dispose()
        $hintFont.Dispose()
        $captionBrush.Dispose()
        $hintBrush.Dispose()
        $format.Dispose()
    })
    $control.Add_MouseEnter({
        $script:PowerButtonHover = $true
        if ($script:PowerButton) { $script:PowerButton.Invalidate() }
    })
    $control.Add_MouseLeave({
        $script:PowerButtonHover = $false
        if ($script:PowerButton) { $script:PowerButton.Invalidate() }
    })
    $control.Add_Click({
        if ($script:PowerButtonState -eq 'active' -or $script:PowerButtonState -eq 'launch') { Stop-CurrentStrategy }
        else { Start-SelectedStrategy }
    })
    [void]$Parent.Controls.Add($control)
    return $control
}

function Get-StrategyTitle {
    param([string]$BaseName)
    if ($BaseName -eq 'general') { return 'Стандартная' }
    if ($BaseName -match '^general \(ALT(\d*)\)$') {
        $number = $Matches[1]
        if ([string]::IsNullOrWhiteSpace($number)) { return 'ALT' }
        return "ALT $number"
    }
    if ($BaseName -match '^general \(FAKE TLS AUTO( ALT(\d*))?\)$') {
        if ($Matches[1]) {
            if ($Matches[2]) { return "FAKE TLS AUTO ALT $($Matches[2])" }
            return 'FAKE TLS AUTO ALT'
        }
        return 'FAKE TLS AUTO'
    }
    if ($BaseName -match '^general \(SIMPLE FAKE( ALT(\d*))?\)$') {
        if ($Matches[1]) {
            if ($Matches[2]) { return "SIMPLE FAKE ALT $($Matches[2])" }
            return 'SIMPLE FAKE ALT'
        }
        return 'SIMPLE FAKE'
    }
    if ($BaseName -eq 'general (EXP)') { return 'EXP' }
    return $BaseName
}

function Get-StrategyOrder {
    param([string]$BaseName)
    if ($BaseName -eq 'general') { return 0 }
    if ($BaseName -match '^general \(ALT(\d*)\)$') {
        $number = 1
        if ($Matches[1]) { $number = [int]$Matches[1] }
        return 10 + $number
    }
    if ($BaseName -match '^general \(FAKE TLS AUTO( ALT(\d*))?\)$') {
        $number = 0
        if ($Matches[1]) {
            $number = 1
            if ($Matches[2]) { $number = [int]$Matches[2] }
        }
        return 40 + $number
    }
    if ($BaseName -eq 'general (EXP)') { return 50 }
    if ($BaseName -match '^general \(SIMPLE FAKE( ALT(\d*))?\)$') {
        $number = 0
        if ($Matches[1]) {
            $number = 1
            if ($Matches[2]) { $number = [int]$Matches[2] }
        }
        return 60 + $number
    }
    return 100
}

function Get-StrategyFamily {
    param([string]$Title)
    if ($Title -eq 'Стандартная') { return 'Базовая стратегия' }
    if ($Title -like 'ALT*') { return 'Вариант ALT' }
    if ($Title -like 'FAKE TLS AUTO*') { return 'Fake TLS Auto' }
    if ($Title -like 'SIMPLE FAKE*') { return 'Simple Fake' }
    if ($Title -eq 'EXP') { return 'Экспериментальная' }
    return 'Стратегия zapret'
}

function Get-StrategyDescription {
    param([string]$Title)
    if ($Title -eq 'Стандартная') {
        return 'Стандартный набор параметров из general.bat. Удобная отправная точка для проверки.'
    }
    if ($Title -like 'ALT*') {
        return 'Альтернативная комбинация параметров из исходного набора. Результат зависит от провайдера и сети.'
    }
    if ($Title -like 'FAKE TLS AUTO*') {
        return 'Вариант Fake TLS Auto из репозитория. Использует собственные параметры исходного BAT-файла.'
    }
    if ($Title -like 'SIMPLE FAKE*') {
        return 'Упрощённый вариант Fake из репозитория. Использует собственные параметры исходного BAT-файла.'
    }
    if ($Title -eq 'EXP') {
        return 'Экспериментальный вариант. Используйте для тестирования, если стандартные варианты не подходят.'
    }
    return 'Готовая стратегия из папки репозитория.'
}

function Get-StrategyTechnicalSummary {
    param([string]$Path)
    try {
        $content = [System.IO.File]::ReadAllText($Path)
        $methodMatches = [regex]::Matches($content, '--dpi-desync=([A-Za-z0-9,_-]+)')
        $methods = @($methodMatches | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
        $repeatMatches = [regex]::Matches($content, '--dpi-desync-repeats=(\d+)')
        $repeats = @($repeatMatches | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
        $parts = @()
        if ($methods.Count -gt 0) { $parts += 'Методы: ' + ($methods -join ', ') }
        if ($repeats.Count -gt 0) { $parts += 'Повторы: ' + ($repeats -join ', ') }
        if ($parts.Count -eq 0) { return 'Параметры будут переданы исходным BAT-файлом.' }
        return ($parts -join "`r`n")
    } catch {
        return 'Не удалось прочитать параметры BAT-файла.'
    }
}

function Get-Strategies {
    $files = @(Get-ChildItem -LiteralPath $script:Root -Filter 'general*.bat' -File -ErrorAction SilentlyContinue)
    $items = foreach ($file in $files) {
        $title = Get-StrategyTitle $file.BaseName
        [pscustomobject]@{
            Title       = $title
            Family      = (Get-StrategyFamily $title)
            Description = (Get-StrategyDescription $title)
            Summary     = (Get-StrategyTechnicalSummary $file.FullName)
            Path        = $file.FullName
            Order       = (Get-StrategyOrder $file.BaseName)
        }
    }
    $sortedItems = $items | Sort-Object -Property Order
    return @($sortedItems)
}

function Get-ServiceInfo {
    $expected = [System.IO.Path]::GetFullPath($script:ExpectedWinws)
    $registryPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\zapret'
    $registry = Get-ItemProperty -LiteralPath $registryPath -ErrorAction SilentlyContinue
    if ($null -eq $registry) {
        return [pscustomobject]@{ Exists = $false; IsOurs = $false; Running = $false; State = 'Не установлена'; Strategy = '' }
    }

    $image = [string]$registry.ImagePath
    $serviceExe = ''
    if ($image -match '(?i)^\s*"?(.+?winws\.exe)"?(?:\s|$)') { $serviceExe = $Matches[1] }
    $isOurs = $false
    if ($serviceExe) {
        try {
            $isOurs = [string]::Equals([System.IO.Path]::GetFullPath($serviceExe), $expected, [System.StringComparison]::OrdinalIgnoreCase)
        } catch { $isOurs = $false }
    }

    $service = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
    $state = 'Остановлена'
    $running = $false
    if ($service) {
        $running = ($service.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Running)
        if ($running) { $state = 'Работает' }
        elseif ($service.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Stopped) { $state = [string]$service.Status }
    }
    $strategy = ''
    if ($registry.PSObject.Properties.Name -contains 'zapret-discord-youtube') {
        $strategy = [string]$registry.'zapret-discord-youtube'
    }
    return [pscustomobject]@{
        Exists   = $true
        IsOurs   = $isOurs
        Running  = ($isOurs -and $running)
        State    = $state
        Strategy = $strategy
    }
}

function Get-WinwsProcesses {
    $expected = [System.IO.Path]::GetFullPath($script:ExpectedWinws)
    try {
        $all = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='winws.exe'" -ErrorAction Stop)
        $mine = foreach ($process in $all) {
            if ([string]::IsNullOrWhiteSpace([string]$process.ExecutablePath)) { continue }
            try {
                $path = [System.IO.Path]::GetFullPath([string]$process.ExecutablePath)
                if ([string]::Equals($path, $expected, [System.StringComparison]::OrdinalIgnoreCase)) { $process }
            } catch { }
        }
        return @($mine)
    } catch {
        return @()
    }
}

function Get-ForeignWinwsProcesses {
    $expected = [System.IO.Path]::GetFullPath($script:ExpectedWinws)
    try {
        $all = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='winws.exe'" -ErrorAction Stop)
        $foreign = foreach ($process in $all) {
            if ([string]::IsNullOrWhiteSpace([string]$process.ExecutablePath)) {
                $process
                continue
            }
            try {
                $path = [System.IO.Path]::GetFullPath([string]$process.ExecutablePath)
                if (-not [string]::Equals($path, $expected, [System.StringComparison]::OrdinalIgnoreCase)) { $process }
            } catch { $process }
        }
        return @($foreign)
    } catch {
        return @()
    }
}

function Get-CurrentStatus {
    $processes = @(Get-WinwsProcesses)
    $service = Get-ServiceInfo
    return [pscustomobject]@{
        Processes = $processes
        ProcessCount = $processes.Count
        Service = $service
        Running = (($processes.Count -gt 0) -or $service.Running)
    }
}

function Get-GameSettings {
    $path = Join-Path $script:Root 'utils\game_filter.enabled'
    $result = [ordered]@{ Mode = 'disabled'; Tcp = '1024-65535'; Udp = '1024-65535' }
    if (-not (Test-Path -LiteralPath $path)) { return [pscustomobject]$result }
    try {
        foreach ($line in [System.IO.File]::ReadAllLines($path)) {
            $parts = $line -split '=', 2
            if ($parts.Count -ne 2) { continue }
            switch ($parts[0].Trim().ToLowerInvariant()) {
                'mode' { $result.Mode = $parts[1].Trim().ToLowerInvariant() }
                'all'  { $result.Mode = 'all' }
                'tcp'  { if ($parts[1].Trim()) { $result.Tcp = $parts[1].Trim() } }
                'udp'  { if ($parts[1].Trim()) { $result.Udp = $parts[1].Trim() } }
            }
        }
    } catch { }
    if ($result.Mode -notin @('disabled', 'all', 'tcp', 'udp')) { $result.Mode = 'disabled' }
    return [pscustomobject]$result
}

function Get-IpSetMode {
    $path = Join-Path $script:Root 'lists\ipset-all.txt'
    if (-not (Test-Path -LiteralPath $path)) { return 'any' }
    try {
        $lines = @([System.IO.File]::ReadAllLines($path) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($lines.Count -eq 0) { return 'any' }
        if ($lines -contains '203.0.113.113/32') { return 'none' }
        return 'loaded'
    } catch {
        return 'unknown'
    }
}

function Write-TextFileAtomic {
    param([string]$Path, [string]$Text)
    $directory = [System.IO.Path]::GetDirectoryName($Path)
    if (-not (Test-Path -LiteralPath $directory)) { [void](New-Item -ItemType Directory -Path $directory -Force) }
    $temporary = $Path + '.tmp-' + [guid]::NewGuid().ToString('N')
    [System.IO.File]::WriteAllText($temporary, $Text, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Validate-PortRanges {
    param([string]$Value, [string]$Label)
    $normalized = ($Value -replace '\s', '')
    if ([string]::IsNullOrWhiteSpace($normalized)) { throw "${Label}: укажите порт или диапазон, например 1024-65535." }
    foreach ($segment in $normalized.Split(',')) {
        if ($segment -match '^([1-9]\d*)(?:-([1-9]\d*))?$') {
            $start = [int]$Matches[1]
            $end = $start
            if ($Matches[2]) { $end = [int]$Matches[2] }
            if ($start -lt 1 -or $end -gt 65535 -or $start -gt $end) { throw "${Label}: порты должны быть в диапазоне 1–65535, а начало диапазона не может быть больше конца." }
        } else {
            throw "${Label}: неверный формат. Используйте порты и диапазоны через запятую, например 443,5000-5100."
        }
    }
    return $normalized
}

function Set-IpSetMode {
    param([ValidateSet('loaded', 'none', 'any')][string]$Mode)
    $listPath = Join-Path $script:Root 'lists\ipset-all.txt'
    $backupPath = $listPath + '.backup'
    $current = Get-IpSetMode
    if ($current -eq $Mode) { return }

    if ($Mode -eq 'loaded') {
        if (-not (Test-Path -LiteralPath $backupPath)) {
            throw 'Резервный список IP не найден. Верните ipset-all.txt.backup вручную или обновите список через service.bat.'
        }
        Copy-Item -LiteralPath $backupPath -Destination $listPath -Force
        Remove-Item -LiteralPath $backupPath -Force
        return
    }

    if ($Mode -eq 'none') {
        if ($current -eq 'loaded' -and (Test-Path -LiteralPath $listPath)) {
            Copy-Item -LiteralPath $listPath -Destination $backupPath -Force
        }
        Write-TextFileAtomic -Path $listPath -Text "203.0.113.113/32`r`n"
        return
    }

    if ($Mode -eq 'any') {
        Write-TextFileAtomic -Path $listPath -Text ''
    }
}

function Load-SettingsIntoUi {
    $game = Get-GameSettings
    $gameModeIndex = @{ disabled = 0; all = 1; tcp = 2; udp = 3 }[$game.Mode]
    $script:GameModeCombo.SelectedIndex = [int]$gameModeIndex
    $script:TcpRangeBox.Text = $game.Tcp
    $script:UdpRangeBox.Text = $game.Udp

    $ipMode = Get-IpSetMode
    $ipModeIndex = @{ loaded = 0; none = 1; any = 2; unknown = 0 }[$ipMode]
    $script:IpSetModeCombo.SelectedIndex = [int]$ipModeIndex
    $script:IpSetCurrentLabel.Text = 'Текущий режим: ' + @{ loaded = 'список загружен'; none = 'IP-адреса не фильтруются'; any = 'фильтруются любые IP'; unknown = 'не удалось прочитать список' }[$ipMode]
    $script:AutoUpdateCheck.Checked = Test-Path -LiteralPath (Join-Path $script:Root 'utils\check_updates.enabled')
}

function Write-UiLog {
    param([string]$Message, [string]$Color = 'Text')
    if (-not $script:EventLog) { return }
    $box = $script:EventLog
    $line = '[' + (Get-Date -Format 'HH:mm:ss') + ']  ' + $Message
    $box.SelectionStart = $box.TextLength
    $box.SelectionLength = 0
    $box.SelectionColor = Get-Color $Color
    $box.AppendText($line + [Environment]::NewLine)
    $box.SelectionColor = $script:Palette.Text
    $box.ScrollToCaret()
    if ($box.TextLength -gt 50000) {
        $cut = $box.Text.IndexOf([Environment]::NewLine, 6000)
        if ($cut -gt 0) {
            $box.Select(0, $cut + [Environment]::NewLine.Length)
            $box.SelectedText = ''
        }
    }
}

function Add-Activity {
    param([string]$Text)
    $timestamp = Get-Date -Format 'HH:mm:ss'
    if ($script:ActivityLabel) { $script:ActivityLabel.Text = $timestamp + '  ·  ' + $Text }
    $color = 'Text'
    if ($Text -match '(?i)ошиб|не удалось|не найден|не найдена|не наш|error') { $color = 'Red' }
    elseif ($Text -match '(?i)подбор|отмен|ожидан') { $color = 'Amber' }
    elseif ($Text -match '(?i)запущ|работает|заверш|выбрана|сохран|готов') { $color = 'Green' }
    Write-UiLog -Message $Text -Color $color
}

function Set-ActivePage {
    param([string]$Name)
    foreach ($key in $script:Pages.Keys) { $script:Pages[$key].Visible = ($key -eq $Name) }
    foreach ($key in $script:NavButtons.Keys) {
        if ($key -eq $Name) {
            $script:NavButtons[$key].BackColor = $script:Palette.CardAlt
            $script:NavButtons[$key].ForeColor = $script:Palette.Accent
            $script:NavButtons[$key].FlatAppearance.BorderSize = 1
            $script:NavButtons[$key].FlatAppearance.BorderColor = $script:Palette.Border
        } else {
            $script:NavButtons[$key].BackColor = $script:Palette.Background
            $script:NavButtons[$key].ForeColor = $script:Palette.Muted
            $script:NavButtons[$key].FlatAppearance.BorderSize = 0
        }
    }
    $titles = @{
        home = 'Главная'
        strategies = 'Стратегии'
        settings = 'Настройки'
        tools = 'Службы и помощь'
    }
    $script:PageTitleLabel.Text = $titles[$Name]
    $script:ActivePage = $Name
}

function Set-StrategyIndex {
    param([int]$Index)
    if ($Index -lt 0 -or $Index -ge $script:Strategies.Count) { return }
    $script:SyncingStrategy = $true
    try {
        $script:SelectedStrategy = $script:Strategies[$Index]
        if ($script:StrategyList -and $script:StrategyList.SelectedIndex -ne $Index) { $script:StrategyList.SelectedIndex = $Index }
        $script:StrategyDetailTitle.Text = $script:SelectedStrategy.Title
        $script:StrategyDetailFamily.Text = $script:SelectedStrategy.Family
        $script:StrategyDetailDescription.Text = $script:SelectedStrategy.Description
        $script:StrategyDetailSummary.Text = $script:SelectedStrategy.Summary
        if ($script:HomeCurrentStrategyLabel) { $script:HomeCurrentStrategyLabel.Text = $script:SelectedStrategy.Title }
        $script:ChosenStrategyLabel.Text = 'Выбрано: ' + $script:SelectedStrategy.Title
    } finally {
        $script:SyncingStrategy = $false
    }
}

function Refresh-StatusUi {
    $status = Get-CurrentStatus
    $script:Status = $status
    $serviceNote = 'Служба zapret: ' + $status.Service.State
    if ($status.Service.Exists -and -not $status.Service.IsOurs) {
        $serviceNote = 'Найдена служба zapret из другой папки — приложение её не изменяет.'
    } elseif ($status.Service.IsOurs -and $status.Service.Strategy) {
        $serviceNote = 'Автозапуск: ' + $status.Service.Strategy
    }

    $launchPending = $false
    if ($script:LaunchProcess) {
        try { $launchPending = -not $script:LaunchProcess.HasExited } catch { $launchPending = $false }
    }
    if ($status.Running) {
        $script:HomeStatusLabel.Text = 'Работает'
        $script:HomeStatusLabel.ForeColor = $script:Palette.Green
        $script:HomeStatusDot.ForeColor = $script:Palette.Green
        $script:HomeStatusDetail.Text = ('Процессов winws.exe: {0}' -f $status.ProcessCount)
        $script:TopStatusLabel.Text = '●  ЗАПРЕТ АКТИВЕН'
        $script:TopStatusLabel.ForeColor = $script:Palette.Green
        $script:PowerButtonState = 'active'
    } elseif ($launchPending) {
        $script:HomeStatusLabel.Text = 'Запуск…'
        $script:HomeStatusLabel.ForeColor = $script:Palette.Amber
        $script:HomeStatusDot.ForeColor = $script:Palette.Amber
        $script:HomeStatusDetail.Text = 'Ожидание запуска выбранной стратегии'
        $script:TopStatusLabel.Text = '●  ЗАПУСК'
        $script:TopStatusLabel.ForeColor = $script:Palette.Amber
        $script:PowerButtonState = 'launch'
    } else {
        $script:HomeStatusLabel.Text = 'Не запущено'
        $script:HomeStatusLabel.ForeColor = $script:Palette.Muted
        $script:HomeStatusDot.ForeColor = $script:Palette.Muted
        $script:HomeStatusDetail.Text = 'Можно запустить выбранную стратегию'
        $script:TopStatusLabel.Text = '●  ГОТОВ'
        $script:TopStatusLabel.ForeColor = $script:Palette.Muted
        $script:PowerButtonState = 'idle'
    }
    if ($script:HomeServiceLabel) {
        $script:HomeServiceLabel.Text = $serviceNote
        if ($status.Service.Exists -and -not $status.Service.IsOurs) { $script:HomeServiceLabel.ForeColor = $script:Palette.Amber }
        elseif ($status.Service.IsOurs) { $script:HomeServiceLabel.ForeColor = $script:Palette.Text }
        else { $script:HomeServiceLabel.ForeColor = $script:Palette.Muted }
    }

    $autoPickBusy = $false
    if ($script:AutoPickWorker) {
        try { $autoPickBusy = $script:AutoPickWorker.IsBusy } catch { $autoPickBusy = $false }
    }
    if ($script:PowerButton) {
        $script:PowerButton.Enabled = -not $autoPickBusy
        $script:PowerButton.Invalidate()
    }

    if ($status.Service.Exists -and -not $status.Service.IsOurs) {
        $script:ServiceSummaryLabel.Text = 'Обнаружена служба zapret, путь которой отличается от этой папки. Менеджер не будет её останавливать или менять.'
        $script:ServiceSummaryLabel.ForeColor = $script:Palette.Amber
    } elseif ($status.Service.IsOurs) {
        $script:ServiceSummaryLabel.Text = ('Служба zapret из этой папки: {0}. Стратегия: {1}' -f $status.Service.State, $(if ($status.Service.Strategy) { $status.Service.Strategy } else { 'не указана' }))
        $script:ServiceSummaryLabel.ForeColor = $script:Palette.Text
    } else {
        $script:ServiceSummaryLabel.Text = 'Служба zapret не установлена. Для настройки автозапуска откройте исходное служебное меню.'
        $script:ServiceSummaryLabel.ForeColor = $script:Palette.Muted
    }

    if (-not $autoPickBusy -and $null -ne $script:LastRunningState -and $script:LastRunningState -ne $status.Running) {
        if ($status.Running) { Add-Activity 'Обнаружен запущенный winws.exe' }
        else { Add-Activity 'winws.exe остановлен' }
    }
    $script:LastRunningState = $status.Running
}

function Read-LaunchLogTail {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    try {
        $lines = @(Get-Content -LiteralPath $Path -Tail 12 -Encoding UTF8 -ErrorAction SilentlyContinue)
        return $lines
    } catch { return @() }
}

function Get-AutoPickTargets {
    $targets = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    $targetFile = Join-Path $script:Root 'utils\targets.txt'
    if (Test-Path -LiteralPath $targetFile) {
        try {
            foreach ($line in [System.IO.File]::ReadAllLines($targetFile)) {
                if ($line -notmatch '^\s*(?<name>[A-Za-z0-9_]+)\s*=\s*"(?<url>https?://[^"]+)"\s*$') { continue }
                $name = $Matches['name']
                $url = $Matches['url']
                $serviceName = ''
                if ($name -match '(?i)discord') { $serviceName = 'Discord' }
                elseif ($name -match '(?i)youtube|youtu|googlevideo') { $serviceName = 'YouTube' }
                if (-not $serviceName) { continue }
                try { $uri = [System.Uri]::new($url) } catch { continue }
                $key = $serviceName + '|' + $uri.AbsoluteUri.TrimEnd('/')
                if (-not $seen.ContainsKey($key)) {
                    [void]$targets.Add([pscustomobject]@{ Name = $name; Url = $uri.AbsoluteUri; Service = $serviceName })
                    $seen[$key] = $true
                }
            }
        } catch { }
    }

    $defaults = @(
        [pscustomobject]@{ Name = 'Discord Main'; Url = 'https://discord.com'; Service = 'Discord' },
        [pscustomobject]@{ Name = 'Discord Gateway'; Url = 'https://gateway.discord.gg'; Service = 'Discord' },
        [pscustomobject]@{ Name = 'Discord CDN'; Url = 'https://cdn.discordapp.com'; Service = 'Discord' },
        [pscustomobject]@{ Name = 'Discord Updates'; Url = 'https://updates.discord.com'; Service = 'Discord' },
        [pscustomobject]@{ Name = 'YouTube Web'; Url = 'https://www.youtube.com'; Service = 'YouTube' },
        [pscustomobject]@{ Name = 'YouTube Short'; Url = 'https://youtu.be'; Service = 'YouTube' },
        [pscustomobject]@{ Name = 'YouTube Images'; Url = 'https://i.ytimg.com'; Service = 'YouTube' },
        [pscustomobject]@{ Name = 'YouTube Video CDN'; Url = 'https://redirector.googlevideo.com'; Service = 'YouTube' }
    )
    foreach ($serviceName in @('Discord', 'YouTube')) {
        $serviceTargetCount = @($targets | Where-Object { $_.Service -eq $serviceName }).Count
        if ($serviceTargetCount -eq 0) {
            foreach ($target in $defaults | Where-Object { $_.Service -eq $serviceName }) {
                [void]$targets.Add($target)
            }
        }
    }

    $limited = New-Object System.Collections.Generic.List[object]
    foreach ($serviceName in @('Discord', 'YouTube')) {
        $serviceTargets = @($targets | Where-Object { $_.Service -eq $serviceName })
        $preferred = New-Object System.Collections.Generic.List[object]
        if ($serviceName -eq 'Discord') { $patterns = @('main|web', 'gateway|cdn') }
        else { $patterns = @('web|main', 'video|redirect|googlevideo|cdn|image') }
        foreach ($pattern in $patterns) {
            $match = @($serviceTargets | Where-Object { $_.Name -match $pattern } | Select-Object -First 1)
            if ($match.Count -gt 0) {
                $alreadyAdded = @($preferred | Where-Object { $_.Url -eq $match[0].Url })
                if ($alreadyAdded.Count -eq 0) { [void]$preferred.Add($match[0]) }
            }
        }
        foreach ($target in $serviceTargets) {
            if ($preferred.Count -ge 2) { break }
            $alreadyAdded = @($preferred | Where-Object { $_.Url -eq $target.Url })
            if ($alreadyAdded.Count -eq 0) { [void]$preferred.Add($target) }
        }
        foreach ($target in @($preferred | Select-Object -First 2)) { [void]$limited.Add($target) }
    }
    return @($limited.ToArray())
}

function Get-AutoPickWinwsProcesses {
    param([string]$ExpectedPath)
    $expected = [System.IO.Path]::GetFullPath($ExpectedPath)
    $all = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='winws.exe'" -ErrorAction Stop)
    $matching = New-Object System.Collections.Generic.List[object]
    foreach ($process in $all) {
        if ([string]::IsNullOrWhiteSpace([string]$process.ExecutablePath)) { continue }
        try {
            $path = [System.IO.Path]::GetFullPath([string]$process.ExecutablePath)
            if ([string]::Equals($path, $expected, [System.StringComparison]::OrdinalIgnoreCase)) {
                [void]$matching.Add($process)
            }
        } catch { }
    }
    return @($matching.ToArray())
}

function Get-AutoPickForeignWinwsProcesses {
    param([string]$ExpectedPath)
    $expected = [System.IO.Path]::GetFullPath($ExpectedPath)
    $all = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='winws.exe'" -ErrorAction Stop)
    $foreign = New-Object System.Collections.Generic.List[object]
    foreach ($process in $all) {
        if ([string]::IsNullOrWhiteSpace([string]$process.ExecutablePath)) {
            [void]$foreign.Add($process)
            continue
        }
        try {
            $path = [System.IO.Path]::GetFullPath([string]$process.ExecutablePath)
            if (-not [string]::Equals($path, $expected, [System.StringComparison]::OrdinalIgnoreCase)) {
                [void]$foreign.Add($process)
            }
        } catch { [void]$foreign.Add($process) }
    }
    return @($foreign.ToArray())
}

function Test-AutoPickZapretServiceRunning {
    $service = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
    return [bool]($service -and $service.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Stopped)
}

function Stop-AutoPickWinwsProcesses {
    param([int[]]$ProcessIds, [string]$ExpectedPath, [int]$TimeoutSeconds = 4)
    $ids = @($ProcessIds | Where-Object { $_ -gt 0 } | Select-Object -Unique)
    if ($ids.Count -eq 0) { return @() }
    foreach ($id in $ids) {
        try {
            $process = Get-CimInstance -ClassName Win32_Process -Filter ("ProcessId={0}" -f [int]$id) -ErrorAction Stop
            if ($process -and $process.Name -ieq 'winws.exe' -and -not [string]::IsNullOrWhiteSpace([string]$process.ExecutablePath)) {
                $path = [System.IO.Path]::GetFullPath([string]$process.ExecutablePath)
                if ([string]::Equals($path, [System.IO.Path]::GetFullPath($ExpectedPath), [System.StringComparison]::OrdinalIgnoreCase)) {
                    Stop-Process -Id ([int]$id) -Force -ErrorAction SilentlyContinue
                }
            }
        } catch { }
    }

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    do {
        $remaining = @(Get-AutoPickWinwsProcesses -ExpectedPath $ExpectedPath | Where-Object { $ids -contains [int]$_.ProcessId })
        if ($remaining.Count -eq 0) { return @() }
        Start-Sleep -Milliseconds 200
    } while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    return @($remaining | ForEach-Object { [int]$_.ProcessId })
}

function Invoke-AutoPickHttpProbe {
    param(
        [object]$Target,
        [string]$CurlPath,
        [string]$TempDirectory,
        [System.ComponentModel.BackgroundWorker]$Worker
    )
    $token = [guid]::NewGuid().ToString('N')
    $outputPath = Join-Path $TempDirectory ($token + '.out')
    $errorPath = Join-Path $TempDirectory ($token + '.err')
    $process = $null
    try {
        $arguments = @('-I', '-sS', '--max-time', '3', '--connect-timeout', '2', '-o', 'NUL', '-w', '%{http_code}', [string]$Target.Url)
        $process = Start-Process -FilePath $CurlPath -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $outputPath -RedirectStandardError $errorPath
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not $process.HasExited -and $watch.Elapsed.TotalSeconds -lt 5) {
            if ($Worker.CancellationPending) {
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                return [pscustomobject]@{ Name = $Target.Name; Service = $Target.Service; Url = $Target.Url; Ok = $false; HttpCode = 'CANCELLED'; Cancelled = $true }
            }
            Start-Sleep -Milliseconds 100
        }
        if (-not $process.HasExited) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            return [pscustomobject]@{ Name = $Target.Name; Service = $Target.Service; Url = $Target.Url; Ok = $false; HttpCode = 'TIMEOUT'; Cancelled = $false }
        }
        $process.Refresh()
        $httpCode = ''
        if (Test-Path -LiteralPath $outputPath) { $httpCode = [System.IO.File]::ReadAllText($outputPath).Trim() }
        $ok = ($process.ExitCode -eq 0 -and $httpCode -match '^\d{3}$')
        $status = if ($ok) { 'HTTP ' + $httpCode } else { 'Нет ответа' }
        return [pscustomobject]@{ Name = $Target.Name; Service = $Target.Service; Url = $Target.Url; Ok = $ok; HttpCode = $status; Cancelled = $false }
    } catch {
        return [pscustomobject]@{ Name = $Target.Name; Service = $Target.Service; Url = $Target.Url; Ok = $false; HttpCode = 'Ошибка проверки'; Cancelled = $false }
    } finally {
        if ($process) {
            try { if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } } catch { }
            try { $process.Dispose() } catch { }
        }
        Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $errorPath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-AutoPickWork {
    param($Worker, $EventArgs, $Payload)
    $results = New-Object System.Collections.Generic.List[object]
    $trackedIds = [System.Collections.Generic.HashSet[int]]::new()
    $testDirectory = Join-Path $env:TEMP ('ZapretManager-AutoPick-' + [guid]::NewGuid().ToString('N'))
    $originalNoUpdate = [System.Environment]::GetEnvironmentVariable('NO_UPDATE_CHECK', 'Process')
    $cancelled = $false
    $workerException = $null
    $cmdProcess = $null

    try {
        [System.Environment]::SetEnvironmentVariable('NO_UPDATE_CHECK', '1', 'Process')
        [void][System.IO.Directory]::CreateDirectory($testDirectory)
        $initialProcesses = @(Get-AutoPickWinwsProcesses -ExpectedPath $Payload.ExpectedWinws)
        if ($initialProcesses.Count -gt 0) { throw 'В этой папке уже запущен winws.exe. Остановите его и повторите автоподбор.' }
        $strategyCount = $Payload.Strategies.Count
        $targetCount = $Payload.Targets.Count

        for ($i = 0; $i -lt $strategyCount; $i++) {
            if ($Worker.CancellationPending) { $cancelled = $true; break }
            $strategy = $Payload.Strategies[$i]
            $cmdProcess = $null
            $candidateIds = @()
            $candidateStarted = $false
            $startupError = ''
            $probes = New-Object System.Collections.Generic.List[object]
            $basePercent = [int][Math]::Floor(($i * 100.0) / $strategyCount)
            $Worker.ReportProgress($basePercent, [pscustomobject]@{
                Message = ('[{0}/{1}] Запуск: {2}' -f ($i + 1), $strategyCount, $strategy.Title)
                Details = 'Подготовка тестовой стратегии…'
            })

            $foreign = @(Get-AutoPickForeignWinwsProcesses -ExpectedPath $Payload.ExpectedWinws)
            if ($foreign.Count -gt 0) { throw 'Во время автоподбора обнаружен winws.exe из другой папки. Проверка остановлена для безопасности.' }
            $service = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
            if ($service -and $service.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
                throw 'Во время автоподбора запущена или останавливается служба zapret. Проверка остановлена; служба не изменялась.'
            }
            $alreadyRunning = @(Get-AutoPickWinwsProcesses -ExpectedPath $Payload.ExpectedWinws)
            if ($alreadyRunning.Count -gt 0) { throw 'Перед запуском очередной стратегии найден работающий winws.exe. Проверка остановлена.' }

            try {
                if (-not (Test-Path -LiteralPath $strategy.Path)) {
                    $startupError = 'Файл стратегии не найден.'
                } else {
                    $logPath = Join-Path $testDirectory ('strategy-{0}.log' -f ($i + 1))
                    [System.IO.File]::WriteAllText($logPath, '', [System.Text.UTF8Encoding]::new($false))
                    $quotedBatch = '"' + $strategy.Path + '"'
                    $quotedLog = '"' + $logPath + '"'
                    $arguments = '/d /s /c "' + $quotedBatch + ' > ' + $quotedLog + ' 2>&1"'
                    $cmdPath = if ($env:ComSpec) { $env:ComSpec } else { Join-Path $env:WINDIR 'System32\cmd.exe' }
                    $cmdProcess = Start-Process -FilePath $cmdPath -ArgumentList $arguments -WorkingDirectory $Payload.Root -WindowStyle Hidden -PassThru
                    $startWatch = [System.Diagnostics.Stopwatch]::StartNew()
                    for ($waitIndex = 0; $waitIndex -lt 60; $waitIndex++) {
                        if ($Worker.CancellationPending) { $cancelled = $true; break }
                        $observed = @(Get-AutoPickWinwsProcesses -ExpectedPath $Payload.ExpectedWinws)
                        foreach ($process in $observed) {
                            $processId = [int]$process.ProcessId
                            if (-not $trackedIds.Contains($processId)) { [void]$trackedIds.Add($processId) }
                            if ($candidateIds -notcontains $processId) { $candidateIds += $processId }
                        }
                        if ($candidateIds.Count -gt 0) { $candidateStarted = $true; break }
                        if ($cmdProcess.HasExited -and $startWatch.Elapsed.TotalSeconds -ge 2) { break }
                        Start-Sleep -Milliseconds 200
                    }
                    if (-not $candidateStarted -and -not $cancelled) { $startupError = 'winws.exe не появился в течение 12 секунд.' }
                }

                if ($candidateStarted -and -not $cancelled) {
                    for ($j = 0; $j -lt $targetCount; $j++) {
                        if ($Worker.CancellationPending) { $cancelled = $true; break }
                        $target = $Payload.Targets[$j]
                        $percent = [int][Math]::Min(99, [Math]::Floor((($i + (($j + 1) / [double]$targetCount)) * 100.0) / $strategyCount))
                        $Worker.ReportProgress($percent, [pscustomobject]@{
                            Message = ('[{0}/{1}] Проверка: {2}' -f ($i + 1), $strategyCount, $strategy.Title)
                            Details = ('{0} — {1}' -f $target.Service, $target.Name)
                        })
                        $probe = Invoke-AutoPickHttpProbe -Target $target -CurlPath $Payload.CurlPath -TempDirectory $testDirectory -Worker $Worker
                        if ($probe.Cancelled) { $cancelled = $true; break }
                        [void]$probes.Add($probe)
                    }
                }
            } finally {
                if ($cmdProcess) {
                    try { if (-not $cmdProcess.HasExited) { Stop-Process -Id $cmdProcess.Id -Force -ErrorAction SilentlyContinue } } catch { }
                    if (Test-AutoPickZapretServiceRunning) {
                        throw 'Во время автоподбора запущена служба zapret. Для безопасности менеджер не останавливал её процессы; проверьте состояние вручную.'
                    }
                    $currentProcesses = @(Get-AutoPickWinwsProcesses -ExpectedPath $Payload.ExpectedWinws)
                    $currentIds = @($currentProcesses | ForEach-Object { [int]$_.ProcessId })
                    foreach ($processId in $currentIds) {
                        if (-not $trackedIds.Contains($processId)) { [void]$trackedIds.Add($processId) }
                    }
                    $remainingIds = @(Stop-AutoPickWinwsProcesses -ProcessIds $currentIds -ExpectedPath $Payload.ExpectedWinws)
                    if ($remainingIds.Count -gt 0) {
                        throw ('Не удалось остановить тестовый winws.exe (PID {0}). Автоподбор прерван.' -f ($remainingIds -join ', '))
                    }
                    foreach ($processId in $currentIds) { [void]$trackedIds.Remove([int]$processId) }
                    foreach ($processId in $candidateIds) { [void]$trackedIds.Remove([int]$processId) }
                    try { $cmdProcess.Dispose() } catch { }
                    $cmdProcess = $null
                }
            }

            if ($cancelled) { break }
            $discordTotal = @($Payload.Targets | Where-Object { $_.Service -eq 'Discord' }).Count
            $youtubeTotal = @($Payload.Targets | Where-Object { $_.Service -eq 'YouTube' }).Count
            $discordProbes = @($probes | Where-Object { $_.Service -eq 'Discord' })
            $youtubeProbes = @($probes | Where-Object { $_.Service -eq 'YouTube' })
            $discordOk = @($discordProbes | Where-Object { $_.Ok }).Count
            $youtubeOk = @($youtubeProbes | Where-Object { $_.Ok }).Count
            $discordScore = if ($discordTotal -gt 0) { [double]$discordOk / [double]$discordTotal } else { 0.0 }
            $youtubeScore = if ($youtubeTotal -gt 0) { [double]$youtubeOk / [double]$youtubeTotal } else { 0.0 }
            $score = ($discordScore + $youtubeScore) / 2.0
            $startupOk = ($candidateStarted -and [string]::IsNullOrWhiteSpace($startupError))
            $totalOk = $discordOk + $youtubeOk
            if (-not $startupOk) { $statusText = 'winws.exe не запустился' }
            elseif ($totalOk -eq $targetCount) { $statusText = 'Все адреса ответили' }
            elseif ($totalOk -gt 0) { $statusText = 'Частичный доступ' }
            else { $statusText = 'Нет HTTP-ответов' }
            [void]$results.Add([pscustomobject]@{
                Title = $strategy.Title
                Path = $strategy.Path
                Order = [int]$strategy.Order
                DiscordOk = $discordOk
                DiscordTotal = $discordTotal
                YouTubeOk = $youtubeOk
                YouTubeTotal = $youtubeTotal
                TotalOk = $totalOk
                Score = [double]$score
                MinimumServiceScore = [double][Math]::Min($discordScore, $youtubeScore)
                StartupOk = [bool]$startupOk
                StartupError = $startupError
                Status = $statusText
                Probes = @($probes.ToArray())
            })
            $donePercent = [int][Math]::Min(99, [Math]::Floor((($i + 1) * 100.0) / $strategyCount))
            $Worker.ReportProgress($donePercent, [pscustomobject]@{
                Message = ('Завершена проверка: {0}' -f $strategy.Title)
                Details = ('Discord {0}/{1} · YouTube {2}/{3}' -f $discordOk, $discordTotal, $youtubeOk, $youtubeTotal)
            })
        }
        if ($Worker.CancellationPending) { $cancelled = $true }
    } catch {
        $workerException = $_.Exception
    } finally {
        if ($cmdProcess) {
            try { if (-not $cmdProcess.HasExited) { Stop-Process -Id $cmdProcess.Id -Force -ErrorAction SilentlyContinue } } catch { }
        }
        try {
            $leftoverIds = @($trackedIds)
            if ($cmdProcess) {
                $leftoverProcesses = @(Get-AutoPickWinwsProcesses -ExpectedPath $Payload.ExpectedWinws)
                $leftoverIds += @($leftoverProcesses | ForEach-Object { [int]$_.ProcessId })
            }
            $leftoverIds = @($leftoverIds | Where-Object { $_ -gt 0 } | Select-Object -Unique)
            if (Test-AutoPickZapretServiceRunning) {
                if ($leftoverIds.Count -gt 0 -and -not $workerException) {
                    $workerException = [System.InvalidOperationException]::new('Служба zapret была запущена во время автоподбора. Её процессы не останавливались; проверьте состояние вручную.')
                }
            } elseif ($leftoverIds.Count -gt 0) {
                $remainingIds = @(Stop-AutoPickWinwsProcesses -ProcessIds $leftoverIds -ExpectedPath $Payload.ExpectedWinws)
                if ($remainingIds.Count -gt 0 -and -not $workerException) {
                    $workerException = [System.InvalidOperationException]::new(('Не удалось завершить тестовый winws.exe (PID {0}).' -f ($remainingIds -join ', ')))
                }
            }
        } catch {
            if (-not $workerException) { $workerException = $_.Exception }
        }
        [System.Environment]::SetEnvironmentVariable('NO_UPDATE_CHECK', $originalNoUpdate, 'Process')
        Remove-Item -LiteralPath $testDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }

    if ($workerException) { throw $workerException }
    $EventArgs.Result = [pscustomobject]@{
        Results = @($results.ToArray())
        Cancelled = [bool]$cancelled
        StrategyCount = $Payload.Strategies.Count
    }
}

function Set-AutoPickControls {
    param([bool]$Busy)
    $enabled = -not $Busy
    if ($script:PowerButton) { $script:PowerButton.Enabled = $enabled }
    if ($script:StrategyList) { $script:StrategyList.Enabled = $enabled }
    if ($script:RunChosenButton) { $script:RunChosenButton.Enabled = $enabled }
    foreach ($button in $script:AutoPickButtons) {
        if ($null -eq $button) { continue }
        $button.Enabled = $true
        if ($Busy) { $button.Text = 'Отменить подбор' }
        else { $button.Text = 'Автоподбор' }
    }
    foreach ($key in @('settings', 'tools')) {
        if ($script:NavButtons.ContainsKey($key)) { $script:NavButtons[$key].Enabled = $enabled }
    }
    if ($script:SaveSettingsButton) { $script:SaveSettingsButton.Enabled = $enabled }
    if ($script:AutoPickProgress) { $script:AutoPickProgress.Visible = $Busy }
}

function Show-AutoPickResultsDialog {
    param([array]$Results, [string]$SelectedPath = '', [bool]$WasCancelled = $false)
    if (-not $Results -or $Results.Count -eq 0) {
        Show-Notice 'Не удалось завершить проверку ни одной стратегии.' 'Автоподбор отменён' ([System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = 'Результаты автоподбора'
    $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $dialog.Size = [System.Drawing.Size]::new(850, 590)
    $dialog.MinimumSize = [System.Drawing.Size]::new(850, 590)
    $dialog.BackColor = $script:Palette.Background
    $dialog.ForeColor = $script:Palette.Text
    $dialog.Font = [System.Drawing.Font]::new('Segoe UI', 9, [System.Drawing.FontStyle]::Regular)
    $dialog.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi

    $heading = if ($WasCancelled) { 'Проверка прервана. Результаты ниже относятся только к уже завершённым тестам.' }
        else { 'Стратегии отсортированы по доступности веб-адресов Discord и YouTube в этой сети.' }
    [void](Add-UiLabel $dialog $heading 18 14 795 28 'Text' 10 -Bold)
    [void](Add-UiLabel $dialog 'Проверялся HTTP-ответ через curl. Это ориентир, а не гарантия работы видео, голосовой связи или приложений.' 18 43 795 38 'Muted' 8)

    $listView = New-Object System.Windows.Forms.ListView
    $listView.Location = [System.Drawing.Point]::new(18, 88)
    $listView.Size = [System.Drawing.Size]::new(798, 390)
    $listView.View = [System.Windows.Forms.View]::Details
    $listView.FullRowSelect = $true
    $listView.GridLines = $true
    $listView.HideSelection = $false
    $listView.MultiSelect = $false
    $listView.BackColor = $script:Palette.Card
    $listView.ForeColor = $script:Palette.Text
    $listView.Font = [System.Drawing.Font]::new('Segoe UI', 9, [System.Drawing.FontStyle]::Regular)
    [void]$listView.Columns.Add('№', 42)
    [void]$listView.Columns.Add('Стратегия', 255)
    [void]$listView.Columns.Add('Discord', 105)
    [void]$listView.Columns.Add('YouTube', 105)
    [void]$listView.Columns.Add('Общий балл', 105)
    [void]$listView.Columns.Add('Результат', 165)

    $rowNumber = 0
    $defaultSelectedItem = $null
    foreach ($result in $Results) {
        $rowNumber++
        $item = [System.Windows.Forms.ListViewItem]::new([string]$rowNumber)
        [void]$item.SubItems.Add([string]$result.Title)
        [void]$item.SubItems.Add(('{0}/{1}' -f $result.DiscordOk, $result.DiscordTotal))
        [void]$item.SubItems.Add(('{0}/{1}' -f $result.YouTubeOk, $result.YouTubeTotal))
        [void]$item.SubItems.Add(('{0:P0}' -f $result.Score))
        [void]$item.SubItems.Add([string]$result.Status)
        $item.Tag = $result
        [void]$listView.Items.Add($item)
        if ($SelectedPath -and [string]::Equals([string]$result.Path, $SelectedPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            $defaultSelectedItem = $item
        }
    }
    [void]$dialog.Controls.Add($listView)

    $useButton = Add-UiButton $dialog 'Использовать выбранную' 18 492 210 42 'secondary'
    $launchButton = Add-UiButton $dialog 'Запустить выбранную' 240 492 210 42 'primary'
    $closeButton = Add-UiButton $dialog 'Закрыть' 694 492 122 42 'secondary'
    $useButton.Enabled = $false
    $launchButton.Enabled = $false
    $closeButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dialog.CancelButton = $closeButton

    $listView.Add_SelectedIndexChanged({
        if ($script:AutoPickDialogList.SelectedItems.Count -eq 0) {
            $script:AutoPickDialogUseButton.Enabled = $false
            $script:AutoPickDialogLaunchButton.Enabled = $false
            return
        }
        $entry = $script:AutoPickDialogList.SelectedItems[0].Tag
        $script:AutoPickDialogUseButton.Enabled = $true
        $script:AutoPickDialogLaunchButton.Enabled = ($entry.TotalOk -gt 0)
        for ($strategyIndex = 0; $strategyIndex -lt $script:Strategies.Count; $strategyIndex++) {
            if ([string]::Equals([string]$script:Strategies[$strategyIndex].Path, [string]$entry.Path, [System.StringComparison]::OrdinalIgnoreCase)) {
                Set-StrategyIndex $strategyIndex
                break
            }
        }
    })
    $useButton.Add_Click({
        if ($script:AutoPickDialogList.SelectedItems.Count -gt 0) {
            $script:AutoPickDialog.Tag = 'select'
            $script:AutoPickDialog.Close()
        }
    })
    $launchButton.Add_Click({
        if ($script:AutoPickDialogList.SelectedItems.Count -gt 0 -and $script:AutoPickDialogList.SelectedItems[0].Tag.TotalOk -gt 0) {
            $script:AutoPickDialog.Tag = 'launch'
            $script:AutoPickDialog.Close()
        }
    })
    $closeButton.Add_Click({ $script:AutoPickDialog.Close() })

    $script:AutoPickDialog = $dialog
    $script:AutoPickDialogList = $listView
    $script:AutoPickDialogUseButton = $useButton
    $script:AutoPickDialogLaunchButton = $launchButton
    if ($defaultSelectedItem) {
        $defaultSelectedItem.Selected = $true
        $defaultSelectedItem.Focused = $true
        $defaultSelectedItem.EnsureVisible()
        $useButton.Enabled = $true
        $launchButton.Enabled = ($defaultSelectedItem.Tag.TotalOk -gt 0)
    }
    [void]$dialog.ShowDialog($script:MainForm)
    $action = [string]$dialog.Tag
    $dialog.Dispose()
    $script:AutoPickDialog = $null
    $script:AutoPickDialogList = $null
    $script:AutoPickDialogUseButton = $null
    $script:AutoPickDialogLaunchButton = $null
    if ($action -eq 'launch') { Start-SelectedStrategy }
}

function Start-AutoPick {
    if ($script:AutoPickWorker -and $script:AutoPickWorker.IsBusy) {
        $script:AutoPickWorker.CancelAsync()
        $script:ActivityLabel.Text = 'ОТМЕНА АВТОПОДБОРА…'
        $script:ActivityDetailsLabel.Text = 'Завершается текущая проверка и останавливается тестовый winws.exe.'
        Add-Activity 'Запрошена отмена автоподбора'
        return
    }
    if ($script:LaunchProcess) {
        try {
            if (-not $script:LaunchProcess.HasExited) {
                Show-Notice 'Дождитесь завершения запуска стратегии, затем повторите автоподбор.' 'Запуск выполняется' ([System.Windows.Forms.MessageBoxIcon]::Information)
                return
            }
            $script:LaunchProcess.Dispose()
            $script:LaunchProcess = $null
        } catch { $script:LaunchProcess = $null }
    }

    $status = Get-CurrentStatus
    if ($status.Running) {
        Show-Notice 'Перед автоподбором остановите текущую стратегию из этой папки. Менеджер не будет прерывать её автоматически.' 'Сначала остановите zapret' ([System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }
    $foreignProcesses = @(Get-ForeignWinwsProcesses)
    if ($foreignProcesses.Count -gt 0) {
        Show-Notice ('Найдены winws.exe из других папок (PID: ' + ($foreignProcesses.ProcessId -join ', ') + '). Закройте их через программу, которая их запустила, затем повторите подбор.') 'Обнаружен другой экземпляр' ([System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }
    $zapretService = Get-Service -Name 'zapret' -ErrorAction SilentlyContinue
    if ($zapretService -and $zapretService.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
        Show-Notice 'Служба zapret работает или меняет состояние. Автоподбор не останавливает и не изменяет службы; дождитесь её остановки и повторите подбор.' 'Служба zapret активна' ([System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }
    $requiredFiles = @('bin\winws.exe', 'bin\WinDivert.dll', 'bin\WinDivert64.sys')
    $missingFiles = @($requiredFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $script:Root $_)) })
    if ($missingFiles.Count -gt 0) {
        Show-Notice ('В сборке не найдены файлы: ' + ($missingFiles -join ', ') + '.') 'Не найдены файлы zapret' ([System.Windows.Forms.MessageBoxIcon]::Error)
        return
    }
    $curlCommand = Get-Command -Name 'curl.exe' -ErrorAction SilentlyContinue
    if (-not $curlCommand -or [string]::IsNullOrWhiteSpace([string]$curlCommand.Source)) {
        Show-Notice 'Для автоподбора нужен встроенный curl.exe из Windows 10/11. Обновите Windows или используйте ручную проверку.' 'curl.exe не найден' ([System.Windows.Forms.MessageBoxIcon]::Error)
        return
    }
    $targets = @(Get-AutoPickTargets)
    if ($targets.Count -eq 0) {
        Show-Notice 'Не удалось подготовить адреса для проверки Discord и YouTube.' 'Нет тестовых адресов' ([System.Windows.Forms.MessageBoxIcon]::Error)
        return
    }

    $discordCount = @($targets | Where-Object { $_.Service -eq 'Discord' }).Count
    $youtubeCount = @($targets | Where-Object { $_.Service -eq 'YouTube' }).Count
    $confirmationText = ('Автоподбор последовательно проверит {0} стратегий по HTTP-ответам от {1} адресов Discord и {2} адресов YouTube. Тест займёт несколько минут.' -f $script:Strategies.Count, $discordCount, $youtubeCount) + "`r`n`r`nКаждый исходный BAT запускается на короткое время, затем менеджер останавливает только winws.exe из этой сборки. Установленные службы он не устанавливает, не удаляет и не останавливает. Запуск BAT может включить TCP timestamps, если они выключены, и создать отсутствующие пользовательские файлы списков — так же, как при обычном запуске стратегии." + "`r`n`r`nВ конце подходящая стратегия будет выбрана, но не запущена автоматически. Продолжить?"
    $answer = [System.Windows.Forms.MessageBox]::Show(
        $confirmationText,
        'Запустить автоподбор стратегий?',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Information
    )
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    Set-ActivePage 'home'
    $script:AutoPickProgress.Value = 0
    Set-AutoPickControls -Busy $true
    $script:ActivityLabel.Text = 'АВТОПОДБОР СТРАТЕГИЙ'
    $script:ActivityDetailsLabel.Text = 'Подготовка проверки… Нажмите «Отменить подбор», чтобы безопасно остановить процесс.'
    $script:LastAutoPickLogMessage = ''
    Add-Activity 'Начат автоподбор стратегий'

    $payload = [pscustomobject]@{
        Root = $script:Root
        ExpectedWinws = $script:ExpectedWinws
        CurlPath = [string]$curlCommand.Source
        Strategies = @($script:Strategies | ForEach-Object { [pscustomobject]@{ Title = $_.Title; Path = $_.Path; Order = $_.Order } })
        Targets = $targets
    }
    $script:AutoPickWorker = New-Object System.ComponentModel.BackgroundWorker
    $script:AutoPickWorker.WorkerReportsProgress = $true
    $script:AutoPickWorker.WorkerSupportsCancellation = $true
    $script:AutoPickWorker.add_DoWork({
        param($sender, $eventArgs)
        Invoke-AutoPickWork -Worker $sender -EventArgs $eventArgs -Payload $eventArgs.Argument
    })
    $script:AutoPickWorker.add_ProgressChanged({
        param($sender, $eventArgs)
        $script:AutoPickProgress.Value = [Math]::Max(0, [Math]::Min(100, $eventArgs.ProgressPercentage))
        if ($eventArgs.UserState) {
            $script:ActivityLabel.Text = $eventArgs.UserState.Message
            $script:ActivityDetailsLabel.Text = $eventArgs.UserState.Details
            if ($script:LastAutoPickLogMessage -ne $eventArgs.UserState.Message) {
                Write-UiLog -Message $eventArgs.UserState.Message -Color 'Muted'
                $script:LastAutoPickLogMessage = $eventArgs.UserState.Message
            }
        }
    })
    $script:AutoPickWorker.add_RunWorkerCompleted({
        param($sender, $eventArgs)
        Set-AutoPickControls -Busy $false
        $script:AutoPickWorker = $null
        Refresh-StatusUi
        if ($script:AutoPickPendingClose) {
            $script:AutoPickPendingClose = $false
            $script:MainForm.Close()
            return
        }
        if ($eventArgs.Error) {
            $errorText = $eventArgs.Error.Message
            $script:ActivityLabel.Text = 'АВТОПОДБОР ОСТАНОВЛЕН'
            $script:ActivityDetailsLabel.Text = $errorText
            if ($script:AutoPickResultLabel) { $script:AutoPickResultLabel.Text = 'Подбор прерван: ' + $errorText }
            Add-Activity ('Автоподбор остановлен: ' + $errorText)
            Show-Notice ('Автоподбор остановлен: ' + $errorText) 'Ошибка автоподбора' ([System.Windows.Forms.MessageBoxIcon]::Error)
            return
        }
        $result = $eventArgs.Result
        if (-not $result -or $result.Results.Count -eq 0) {
            $script:ActivityLabel.Text = 'АВТОПОДБОР ОТМЕНЁН'
            $script:ActivityDetailsLabel.Text = 'Не завершена проверка ни одной стратегии.'
            Add-Activity 'Автоподбор не завершил ни одной проверки'
            return
        }
        $ranked = @($result.Results | Sort-Object -Property @{ Expression = 'Score'; Descending = $true }, @{ Expression = 'MinimumServiceScore'; Descending = $true }, @{ Expression = 'TotalOk'; Descending = $true }, @{ Expression = 'Order'; Descending = $false })
        $selectedPath = ''
        $hasWorkingStrategy = (@($ranked | Where-Object { $_.TotalOk -gt 0 }).Count -gt 0)
        if (-not $result.Cancelled -and $hasWorkingStrategy) {
            $best = $ranked[0]
            $selectedPath = [string]$best.Path
            for ($strategyIndex = 0; $strategyIndex -lt $script:Strategies.Count; $strategyIndex++) {
                if ([string]::Equals([string]$script:Strategies[$strategyIndex].Path, $selectedPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                    Set-StrategyIndex $strategyIndex
                    break
                }
            }
            $script:ActivityLabel.Text = 'АВТОПОДБОР ЗАВЕРШЁН'
            $script:ActivityDetailsLabel.Text = ('Выбрана {0}: Discord {1}/{2}, YouTube {3}/{4}. Стратегия не запущена.' -f $best.Title, $best.DiscordOk, $best.DiscordTotal, $best.YouTubeOk, $best.YouTubeTotal)
            if ($script:AutoPickResultLabel) { $script:AutoPickResultLabel.Text = $script:ActivityDetailsLabel.Text + ' Тест не гарантирует работу видео/голоса.' }
            Add-Activity ('Автоподбор завершён; выбрана стратегия ' + $best.Title)
        } elseif ($result.Cancelled) {
            $script:ActivityLabel.Text = 'АВТОПОДБОР ОТМЕНЁН'
            $script:ActivityDetailsLabel.Text = ('Проверено стратегий: {0}/{1}. Выбор не изменён.' -f $ranked.Count, $result.StrategyCount)
            if ($script:AutoPickResultLabel) { $script:AutoPickResultLabel.Text = $script:ActivityDetailsLabel.Text }
            Add-Activity ('Автоподбор отменён после проверки ' + $ranked.Count + ' стратегий')
        } else {
            $script:ActivityLabel.Text = 'РАБОЧАЯ СТРАТЕГИЯ НЕ НАЙДЕНА'
            $script:ActivityDetailsLabel.Text = 'Ни один тестовый адрес не ответил. Проверьте интернет и попробуйте ручной запуск.'
            if ($script:AutoPickResultLabel) { $script:AutoPickResultLabel.Text = $script:ActivityDetailsLabel.Text + ' Текущий выбор не изменён.' }
            Add-Activity 'Автоподбор: рабочая стратегия не найдена'
        }
        $script:AutoPickProgress.Value = 100
        Show-AutoPickResultsDialog -Results $ranked -SelectedPath $selectedPath -WasCancelled ([bool]$result.Cancelled)
    })
    $script:AutoPickWorker.RunWorkerAsync($payload)
}

function Start-SelectedStrategy {
    if (-not $script:SelectedStrategy) {
        Show-Notice 'Сначала выберите стратегию.'
        return
    }
    if ($script:LaunchProcess) {
        try {
            if (-not $script:LaunchProcess.HasExited) {
                Show-Notice 'Запуск стратегии уже выполняется. Дождитесь проверки статуса.' 'Запуск выполняется' ([System.Windows.Forms.MessageBoxIcon]::Information)
                return
            }
            $script:LaunchProcess.Dispose()
            $script:LaunchProcess = $null
        } catch { $script:LaunchProcess = $null }
    }
    $status = Get-CurrentStatus
    if ($status.Running) {
        Refresh-StatusUi
        Show-Notice 'В этой папке уже запущен winws.exe или служба zapret. Сначала остановите текущий экземпляр, затем запускайте другую стратегию.' 'Стратегия уже запущена' ([System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }
    $foreignProcesses = @(Get-ForeignWinwsProcesses)
    if ($foreignProcesses.Count -gt 0) {
        Show-Notice ('Найдены процессы winws.exe из других папок: ' + ($foreignProcesses.ProcessId -join ', ') + '. Остановите их через приложение, которое их запустило. Менеджер не будет завершать чужие процессы.') 'Обнаружен другой экземпляр' ([System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }
    $requiredFiles = @('bin\winws.exe', 'bin\WinDivert.dll', 'bin\WinDivert64.sys')
    $missingFiles = @($requiredFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $script:Root $_)) })
    if ($missingFiles.Count -gt 0) {
        Show-Notice ('В сборке не найдены файлы: ' + ($missingFiles -join ', ') + '. Проверьте распаковку и карантин антивируса.') 'Не найдены файлы zapret' ([System.Windows.Forms.MessageBoxIcon]::Error)
        return
    }
    if (-not (Test-Path -LiteralPath $script:SelectedStrategy.Path)) {
        Show-Notice 'Файл выбранной стратегии не найден.' 'Ошибка' ([System.Windows.Forms.MessageBoxIcon]::Error)
        return
    }

    try {
        $script:LaunchLogPath = Join-Path $env:TEMP ('ZapretManager-' + [guid]::NewGuid().ToString('N') + '.log')
        [System.IO.File]::WriteAllText($script:LaunchLogPath, '', [System.Text.UTF8Encoding]::new($false))
        $quotedBatch = '"' + $script:SelectedStrategy.Path + '"'
        $quotedLog = '"' + $script:LaunchLogPath + '"'
        $arguments = '/d /s /c "' + $quotedBatch + ' > ' + $quotedLog + ' 2>&1"'
        $script:LaunchProcess = Start-Process -FilePath $env:ComSpec -ArgumentList $arguments -WorkingDirectory $script:Root -WindowStyle Hidden -PassThru
        $script:HomeStatusLabel.Text = 'Запуск…'
        $script:HomeStatusLabel.ForeColor = $script:Palette.Amber
        $script:HomeStatusDot.ForeColor = $script:Palette.Amber
        $script:PowerButtonState = 'launch'
        if ($script:PowerButton) { $script:PowerButton.Invalidate() }
        $script:TopStatusLabel.Text = '●  ЗАПУСК'
        $script:TopStatusLabel.ForeColor = $script:Palette.Amber
        Add-Activity ('Запущена стратегия ' + $script:SelectedStrategy.Title)
        $script:ActivityDetailsLabel.Text = 'Стратегия запускается через исходный файл ' + [System.IO.Path]::GetFileName($script:SelectedStrategy.Path) + '. Проверка статуса выполняется автоматически.'
        Set-ActivePage 'home'
        Refresh-StatusUi
    } catch {
        Show-Notice ('Не удалось запустить стратегию: ' + $_.Exception.Message) 'Ошибка запуска' ([System.Windows.Forms.MessageBoxIcon]::Error)
    }
}

function Stop-CurrentStrategy {
    $status = Get-CurrentStatus
    if (-not $status.Running -and $script:LaunchProcess) {
        try {
            if (-not $script:LaunchProcess.HasExited) {
                $answer = [System.Windows.Forms.MessageBox]::Show(
                    'Отменить выполняющийся запуск выбранной стратегии?',
                    'Отменить запуск',
                    [System.Windows.Forms.MessageBoxButtons]::YesNo,
                    [System.Windows.Forms.MessageBoxIcon]::Warning
                )
                if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
                    Stop-Process -Id $script:LaunchProcess.Id -Force -ErrorAction SilentlyContinue
                    $script:LaunchProcess.Dispose()
                    $script:LaunchProcess = $null
                    Add-Activity 'Запуск стратегии отменён'
                    Refresh-StatusUi
                }
                return
            }
        } catch { $script:LaunchProcess = $null }
    }
    if (-not $status.Running) {
        Refresh-StatusUi
        Add-Activity 'Останавливать нечего'
        return
    }

    $targetCount = $status.ProcessCount
    $targetDescription = if ($targetCount -gt 0) { "$targetCount процесс(а) winws.exe" } else { 'службу zapret' }
    $confirmText = "Остановить $targetDescription из текущей папки? Если служба zapret настроена на автозапуск, она будет остановлена, но останется установленной.`r`n`r`nПроцессы winws.exe из других папок приложение не затрагивает."
    $answer = [System.Windows.Forms.MessageBox]::Show(
        $confirmText,
        'Остановить zapret?',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    try {
        if ($status.Service.IsOurs -and $status.Service.Running) {
            & (Join-Path $env:WINDIR 'System32\sc.exe') stop zapret | Out-Null
        }
        foreach ($process in $status.Processes) {
            Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Milliseconds 500
        Add-Activity 'Остановка запрошена'
        Refresh-StatusUi
    } catch {
        Show-Notice ('Не удалось остановить zapret: ' + $_.Exception.Message) 'Ошибка остановки' ([System.Windows.Forms.MessageBoxIcon]::Error)
    }
}

function Save-SettingsFromUi {
    try {
        $modeMap = @('disabled', 'all', 'tcp', 'udp')
        $mode = $modeMap[$script:GameModeCombo.SelectedIndex]
        $tcp = Validate-PortRanges -Value $script:TcpRangeBox.Text -Label 'TCP'
        $udp = Validate-PortRanges -Value $script:UdpRangeBox.Text -Label 'UDP'

        $ipModeMap = @('loaded', 'none', 'any')
        $ipMode = $ipModeMap[$script:IpSetModeCombo.SelectedIndex]
        if ($ipMode -eq 'any' -and (Get-IpSetMode) -ne 'any') {
            $confirmation = [System.Windows.Forms.MessageBox]::Show(
                'Режим «Любой IP» расширяет действие IP-фильтров на адреса вне текущего списка и может повлиять на доступ к обычным сайтам. Продолжить?',
                'Подтвердите изменение IPSet',
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            if ($confirmation -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }
        Set-IpSetMode -Mode $ipMode

        $gamePath = Join-Path $script:Root 'utils\game_filter.enabled'
        $gameText = "mode=$mode`r`ntcp=$tcp`r`nudp=$udp`r`n"
        Write-TextFileAtomic -Path $gamePath -Text $gameText

        $updatePath = Join-Path $script:Root 'utils\check_updates.enabled'
        if ($script:AutoUpdateCheck.Checked) {
            if (-not (Test-Path -LiteralPath $updatePath)) { Write-TextFileAtomic -Path $updatePath -Text "ENABLED`r`n" }
        } elseif (Test-Path -LiteralPath $updatePath) {
            Remove-Item -LiteralPath $updatePath -Force
        }

        Load-SettingsIntoUi
        Add-Activity 'Настройки сохранены'
        $script:ActivityDetailsLabel.Text = 'Настройки записаны в utils\game_filter.enabled, lists\ipset-all.txt и utils\check_updates.enabled. Перезапустите zapret, чтобы применить их.'
        Show-Notice 'Настройки сохранены. Фильтр игр и список IP применятся при следующем запуске стратегии. Если zapret уже работает, остановите его и запустите снова.'
    } catch {
        Show-Notice ('Не удалось сохранить настройки: ' + $_.Exception.Message) 'Ошибка настроек' ([System.Windows.Forms.MessageBoxIcon]::Error)
    }
}

function Open-ServiceMenu {
    $serviceBat = Join-Path $script:Root 'service.bat'
    if (-not (Test-Path -LiteralPath $serviceBat)) {
        Show-Notice 'Файл service.bat не найден в корне сборки.' 'Служебное меню недоступно' ([System.Windows.Forms.MessageBoxIcon]::Error)
        return
    }
    try {
        $arguments = '/d /s /k ""' + $serviceBat + '" admin"'
        Start-Process -FilePath $env:ComSpec -ArgumentList $arguments -WorkingDirectory $script:Root -WindowStyle Normal | Out-Null
        Add-Activity 'Открыто исходное служебное меню'
    } catch {
        Show-Notice ('Не удалось открыть service.bat: ' + $_.Exception.Message) 'Ошибка' ([System.Windows.Forms.MessageBoxIcon]::Error)
    }
}

function Open-ZapretFolder {
    try { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $script:Root + '"') | Out-Null }
    catch { Show-Notice ('Не удалось открыть папку: ' + $_.Exception.Message) 'Ошибка' ([System.Windows.Forms.MessageBoxIcon]::Error) }
}

$script:Strategies = @(Get-Strategies)
if ($script:Strategies.Count -eq 0) {
    Show-Notice 'Не найдено ни одного файла general*.bat. Поместите папку app внутрь полной сборки zapret.' 'Стратегии не найдены' ([System.Windows.Forms.MessageBoxIcon]::Error)
    exit
}

$form = New-Object System.Windows.Forms.Form
$script:MainForm = $form
$form.Text = 'Zapret Manager'
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.Size = [System.Drawing.Size]::new(1120, 800)
$form.MinimumSize = [System.Drawing.Size]::new(1000, 720)
$form.BackColor = $script:Palette.Background
$form.ForeColor = $script:Palette.Text
$form.Font = [System.Drawing.Font]::new('Segoe UI', 9, [System.Drawing.FontStyle]::Regular)
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi

$topBar = Add-UiPanel $form 0 0 $form.ClientSize.Width 64 'Background'
$script:TopBar = $topBar
$brandMark = Add-UiPanel $topBar 20 13 36 36 'Accent'
Set-UiRoundedRegion -Control $brandMark -Radius 10
$brandMarkLabel = Add-UiLabel $brandMark 'Z' 0 0 36 36 'Text' 16 -Bold -Align ([System.Drawing.ContentAlignment]::MiddleCenter)
$brandMarkLabel.ForeColor = [System.Drawing.Color]::White
[void](Add-UiLabel $topBar 'ZAPRET' 68 9 112 23 'Text' 13 -Bold)
[void](Add-UiLabel $topBar 'CONTROL CENTER' 69 31 126 16 'Muted' 7 -Bold)
$script:PageTitleLabel = Add-UiLabel $topBar 'Главная' 205 16 150 32 'Text' 11 -Bold
$headerRule = Add-UiPanel $topBar 0 63 $topBar.ClientSize.Width 1 'Border'
$headerRule.Anchor = [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Bottom

$script:NavButtons.home = Add-UiButton $topBar 'Главная' 0 12 100 40 'nav'
$script:NavButtons.strategies = Add-UiButton $topBar 'Стратегии' 0 12 108 40 'nav'
$script:NavButtons.settings = Add-UiButton $topBar 'Настройки' 0 12 106 40 'nav'
$script:NavButtons.tools = Add-UiButton $topBar 'Службы' 0 12 96 40 'nav'
$script:NavButtons.home.Add_Click({ Set-ActivePage 'home' })
$script:NavButtons.strategies.Add_Click({ Set-ActivePage 'strategies' })
$script:NavButtons.settings.Add_Click({ Set-ActivePage 'settings' })
$script:NavButtons.tools.Add_Click({ Set-ActivePage 'tools' })
$script:TopStatusPill = Add-UiPanel $topBar 0 15 138 34 'CardAlt' -Border
$script:TopStatusLabel = Add-UiLabel $script:TopStatusPill '●  ГОТОВ' 0 0 138 34 'Muted' 8 -Bold -Align ([System.Drawing.ContentAlignment]::MiddleCenter)

$contentWidth = [Math]::Min(960, ($form.ClientSize.Width - 48))
$contentHost = Add-UiPanel $form ([Math]::Max(24, [int](($form.ClientSize.Width - $contentWidth) / 2))) 76 $contentWidth ($form.ClientSize.Height - 92) 'Background'
$script:ContentHost = $contentHost
$contentHost.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right

function New-Page {
    param([string]$Name)
    $page = Add-UiPanel $script:ContentHost 0 0 $script:ContentHost.ClientSize.Width $script:ContentHost.ClientSize.Height 'Background'
    $page.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $page.AutoScroll = $true
    $script:Pages[$Name] = $page
    return $page
}

$homePage = New-Page 'home'
$script:HomePage = $homePage
$strategyPage = New-Page 'strategies'
$settingsPage = New-Page 'settings'
$toolsPage = New-Page 'tools'

# Главная — центральное действие, живой статус и журнал событий.
$script:HomeTitleLabel = Add-UiLabel $homePage 'Контроль подключения' 0 8 960 34 'Text' 22 -Bold -Align ([System.Drawing.ContentAlignment]::MiddleCenter)
$script:HomeSubtitleLabel = Add-UiLabel $homePage 'Запускайте и настраивайте стратегии zapret для Discord и YouTube' 0 43 960 22 'Muted' 9 -Align ([System.Drawing.ContentAlignment]::MiddleCenter)
$script:PowerButton = New-PowerButton $homePage 0 82 220
$script:HomeAutoPickButton = Add-UiButton $homePage 'Автоподбор стратегий' 0 0 180 36 'secondary'

$script:HomeMetricsTitle = Add-UiLabel $homePage 'СОСТОЯНИЕ СИСТЕМЫ' 0 0 245 20 'Muted' 8 -Bold
$script:HomeStatusDot = Add-UiLabel $homePage '●' 0 0 16 20 'Muted' 9 -Bold
$script:HomeStatusLabel = Add-UiLabel $homePage 'Проверка…' 0 0 220 24 'Text' 14 -Bold
$script:HomeStatusDetail = Add-UiLabel $homePage 'Проверка процессов zapret' 0 0 250 24 'Muted' 8
$script:HomeMetricDivider = Add-UiPanel $homePage 0 0 250 1 'Border'
$script:HomeStrategyCaption = Add-UiLabel $homePage 'ВЫБРАННАЯ СТРАТЕГИЯ' 0 0 250 18 'Muted' 8 -Bold
$script:HomeCurrentStrategyLabel = Add-UiLabel $homePage 'Стандартная' 0 0 250 24 'Text' 11 -Bold
$script:HomeServiceLabel = Add-UiLabel $homePage 'Служба zapret: проверка…' 0 0 260 42 'Muted' 8

$script:AutoPickProgress = New-Object System.Windows.Forms.ProgressBar
$script:AutoPickProgress.Location = [System.Drawing.Point]::new(0, 350)
$script:AutoPickProgress.Size = [System.Drawing.Size]::new(960, 5)
$script:AutoPickProgress.Minimum = 0
$script:AutoPickProgress.Maximum = 100
$script:AutoPickProgress.Value = 0
$script:AutoPickProgress.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
$script:AutoPickProgress.ForeColor = $script:Palette.Accent
$script:AutoPickProgress.Visible = $false
[void]$homePage.Controls.Add($script:AutoPickProgress)
$script:HomeDivider = Add-UiPanel $homePage 0 363 960 1 'Border'

$script:HomeLogTitle = Add-UiLabel $homePage 'Журнал событий' 0 376 170 22 'Text' 12 -Bold
$script:ActivityLabel = Add-UiLabel $homePage 'ОЖИДАНИЕ' 176 377 485 20 'Muted' 8 -Bold
$script:HomeCopyLogButton = Add-UiButton $homePage 'Копировать' 0 371 112 32 'secondary'
$script:HomeClearLogButton = Add-UiButton $homePage 'Очистить' 0 371 92 32 'secondary'
$script:HomeCopyLogButton.Add_Click({
    if (-not [string]::IsNullOrWhiteSpace($script:EventLog.Text)) {
        try { [System.Windows.Forms.Clipboard]::SetText($script:EventLog.Text); Add-Activity 'Журнал скопирован в буфер обмена' }
        catch { Show-Notice ('Не удалось скопировать журнал: ' + $_.Exception.Message) 'Буфер обмена' ([System.Windows.Forms.MessageBoxIcon]::Warning) }
    }
})
$script:HomeClearLogButton.Add_Click({
    $script:EventLog.Clear()
    Add-Activity 'Журнал очищен'
})
$script:ActivityDetailsLabel = Add-UiLabel $homePage 'События запуска, остановки и автоподбора будут отображаться здесь.' 0 400 960 18 'Muted' 8
$script:EventLogPanel = Add-UiPanel $homePage 0 423 960 220 'Card' -Border
$script:EventLog = New-Object System.Windows.Forms.RichTextBox
$script:EventLog.Location = [System.Drawing.Point]::new(14, 12)
$script:EventLog.Size = [System.Drawing.Size]::new(932, 196)
$script:EventLog.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$script:EventLog.ReadOnly = $true
$script:EventLog.DetectUrls = $false
$script:EventLog.HideSelection = $false
$script:EventLog.Multiline = $true
$script:EventLog.WordWrap = $true
$script:EventLog.ScrollBars = [System.Windows.Forms.RichTextBoxScrollBars]::Vertical
$script:EventLog.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$script:EventLog.BackColor = $script:Palette.Card
$script:EventLog.ForeColor = $script:Palette.Text
$script:EventLog.Font = [System.Drawing.Font]::new('Consolas', 9, [System.Drawing.FontStyle]::Regular)
[void]$script:EventLogPanel.Controls.Add($script:EventLog)
$script:HomeFooterLabel = Add-UiLabel $homePage '●  ZAPRET MANAGER  ·  ЛОКАЛЬНОЕ УПРАВЛЕНИЕ' 0 0 960 18 'Muted' 7 -Align ([System.Drawing.ContentAlignment]::MiddleRight)
$script:AutoPickButtons = @($script:HomeAutoPickButton)
$script:HomeAutoPickButton.Add_Click({ Start-AutoPick })

# Стратегии
$script:StrategyPageTitle = Add-UiLabel $strategyPage 'Набор стратегий' 0 0 720 34 'Text' 22 -Bold
$script:StrategyPageSubtitle = Add-UiLabel $strategyPage 'Автоподбор сравнивает ответы Discord и YouTube; результаты зависят от провайдера и текущей сети.' 1 38 840 24 'Muted' 9
$strategyListCard = Add-UiPanel $strategyPage 0 74 328 518 'Card' -Border
$script:StrategyListCard = $strategyListCard
[void](Add-UiLabel $strategyListCard 'ДОСТУПНЫЕ ВАРИАНТЫ' 16 14 285 20 'Muted' 8 -Bold)
$script:StrategyList = New-Object System.Windows.Forms.ListBox
$script:StrategyList.Location = [System.Drawing.Point]::new(14, 43)
$script:StrategyList.Size = [System.Drawing.Size]::new(298, 456)
$script:StrategyList.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$script:StrategyList.BackColor = $script:Palette.Card
$script:StrategyList.ForeColor = $script:Palette.Text
$script:StrategyList.Font = [System.Drawing.Font]::new('Segoe UI', 10, [System.Drawing.FontStyle]::Regular)
$script:StrategyList.IntegralHeight = $false
foreach ($strategy in $script:Strategies) { [void]$script:StrategyList.Items.Add($strategy.Title) }
[void]$strategyListCard.Controls.Add($script:StrategyList)

$strategyDetailsCard = Add-UiPanel $strategyPage 348 74 496 518 'Card' -Border
$script:StrategyDetailsCard = $strategyDetailsCard
$script:StrategyDetailFamily = Add-UiLabel $strategyDetailsCard 'СТРАТЕГИЯ' 20 18 450 20 'Accent' 8 -Bold
$script:StrategyDetailTitle = Add-UiLabel $strategyDetailsCard 'Стандартная' 20 43 450 38 'Text' 21 -Bold
$script:StrategyDetailDescription = Add-UiLabel $strategyDetailsCard '' 20 91 450 72 'Muted' 9
[void](Add-UiLabel $strategyDetailsCard 'ПАРАМЕТРЫ ИЗ ФАЙЛА' 20 179 450 20 'Muted' 8 -Bold)
$script:StrategyDetailSummary = Add-UiLabel $strategyDetailsCard '' 20 205 450 74 'Text' 9
[void](Add-UiLabel $strategyDetailsCard 'Источник: текущая папка репозитория' 20 305 450 20 'Muted' 8)
$script:ChosenStrategyLabel = Add-UiLabel $strategyDetailsCard 'Выбрано: —' 20 346 450 22 'Muted' 9
$chooseStrategyButton = Add-UiButton $strategyDetailsCard 'Выбрать стратегию' 20 387 210 44 'secondary'
$script:RunChosenButton = Add-UiButton $strategyDetailsCard 'Запустить' 244 387 210 44 'primary'
$script:StrategyAutoPickButton = Add-UiButton $strategyDetailsCard 'Автоподбор' 20 443 210 42 'secondary'
$script:AutoPickResultLabel = Add-UiLabel $strategyDetailsCard 'Автоподбор сравнит HTTP-доступность Discord и YouTube. Выбор будет предложен без автоматического запуска.' 244 442 210 68 'Muted' 8
$script:AutoPickButtons = @($script:HomeAutoPickButton, $script:StrategyAutoPickButton)
$chooseStrategyButton.Add_Click({ Set-ActivePage 'home'; Add-Activity ('Выбрана стратегия ' + $script:SelectedStrategy.Title) })
$script:RunChosenButton.Add_Click({ Start-SelectedStrategy })
$script:StrategyAutoPickButton.Add_Click({ Start-AutoPick })
$script:StrategyList.Add_SelectedIndexChanged({
    if (-not $script:SyncingStrategy -and $script:StrategyList.SelectedIndex -ge 0) {
        Set-StrategyIndex $script:StrategyList.SelectedIndex
    }
})

# Настройки
$script:SettingsPageTitle = Add-UiLabel $settingsPage 'Настройки фильтров' 0 0 720 34 'Text' 22 -Bold
$script:SettingsPageSubtitle = Add-UiLabel $settingsPage 'Изменения сохраняются рядом с исходными списками и применяются при следующем запуске.' 1 38 840 24 'Muted' 9
$gameCard = Add-UiPanel $settingsPage 0 74 844 197 'Card' -Border
$script:GameCard = $gameCard
[void](Add-UiLabel $gameCard 'Фильтр для игр и UDP/TCP-портов' 18 13 600 24 'Text' 12 -Bold)
[void](Add-UiLabel $gameCard 'По умолчанию выключен. Включайте только если нужно обработать трафик игры.' 19 40 795 22 'Muted' 8)
[void](Add-UiLabel $gameCard 'Режим' 20 73 240 18 'Muted' 8 -Bold)
$script:GameModeCombo = Add-UiComboBox $gameCard 20 94 242 34
foreach ($modeText in @('Выключен', 'TCP + UDP', 'Только TCP', 'Только UDP')) { [void]$script:GameModeCombo.Items.Add($modeText) }
[void](Add-UiLabel $gameCard 'Диапазон TCP-портов' 294 73 220 18 'Muted' 8 -Bold)
$script:TcpRangeBox = Add-UiTextBox $gameCard 294 94 224 34
[void](Add-UiLabel $gameCard 'Диапазон UDP-портов' 550 73 220 18 'Muted' 8 -Bold)
$script:UdpRangeBox = Add-UiTextBox $gameCard 550 94 244 34
[void](Add-UiLabel $gameCard 'Пример: 1024-65535 или 443,5000-5100. После сохранения перезапустите стратегию.' 20 146 790 20 'Muted' 8)

$ipSetCard = Add-UiPanel $settingsPage 0 287 844 137 'Card' -Border
$script:IpSetCard = $ipSetCard
[void](Add-UiLabel $ipSetCard 'IPSet Filter' 18 12 350 24 'Text' 12 -Bold)
[void](Add-UiLabel $ipSetCard 'Выберите, какие IP-адреса попадут под фильтры стратегий.' 19 39 770 20 'Muted' 8)
$script:IpSetModeCombo = Add-UiComboBox $ipSetCard 20 72 332 34
foreach ($modeText in @('Использовать список', 'Не фильтровать IP', 'Любой IP')) { [void]$script:IpSetModeCombo.Items.Add($modeText) }
$script:IpSetCurrentLabel = Add-UiLabel $ipSetCard '' 374 75 430 25 'Muted' 8
[void](Add-UiLabel $ipSetCard '«Любой IP» может затронуть сайты и приложения вне списка.' 20 108 780 18 'Amber' 8)

$updateCard = Add-UiPanel $settingsPage 0 440 844 83 'Card' -Border
$script:UpdateCard = $updateCard
$script:AutoUpdateCheck = New-Object System.Windows.Forms.CheckBox
$script:AutoUpdateCheck.Text = 'Разрешить фоновую проверку обновлений при запуске стратегии'
$script:AutoUpdateCheck.Location = [System.Drawing.Point]::new(18, 13)
$script:AutoUpdateCheck.Size = [System.Drawing.Size]::new(780, 26)
$script:AutoUpdateCheck.ForeColor = $script:Palette.Text
$script:AutoUpdateCheck.BackColor = [System.Drawing.Color]::Transparent
$script:AutoUpdateCheck.Font = [System.Drawing.Font]::new('Segoe UI', 9, [System.Drawing.FontStyle]::Regular)
[void]$updateCard.Controls.Add($script:AutoUpdateCheck)
[void](Add-UiLabel $updateCard 'Переключатель меняет наличие utils\check_updates.enabled.' 20 43 790 20 'Muted' 8)
$script:SaveSettingsButton = Add-UiButton $settingsPage 'Сохранить настройки' 0 547 204 46 'primary'
$settingsNote = Add-UiLabel $settingsPage 'Настройки не перезапускают winws.exe автоматически.' 220 550 600 40 'Muted' 9
$script:SettingsNote = $settingsNote
$script:SaveSettingsButton.Add_Click({ Save-SettingsFromUi })

# Службы и помощь
$script:ToolsPageTitle = Add-UiLabel $toolsPage 'Службы и диагностика' 0 0 720 34 'Text' 22 -Bold
$script:ToolsPageSubtitle = Add-UiLabel $toolsPage 'Для расширенного управления используется оригинальный service.bat из сборки.' 1 38 840 24 'Muted' 9
$serviceCard = Add-UiPanel $toolsPage 0 74 844 158 'Card' -Border
$script:ServiceCard = $serviceCard
[void](Add-UiLabel $serviceCard 'СЛУЖБА АВТОЗАПУСКА' 18 14 300 20 'Muted' 8 -Bold)
$script:ServiceSummaryLabel = Add-UiLabel $serviceCard 'Проверка статуса…' 20 43 795 48 'Text' 9
$openServiceButton = Add-UiButton $serviceCard 'Открыть service.bat' 20 101 210 40 'primary'
$serviceRefreshButton = Add-UiButton $serviceCard 'Обновить статус' 244 101 178 40 'secondary'
$openServiceButton.Add_Click({ Open-ServiceMenu })
$serviceRefreshButton.Add_Click({ Refresh-StatusUi; Add-Activity 'Статус службы обновлён' })

$toolsCard = Add-UiPanel $toolsPage 0 249 844 152 'Card' -Border
$script:ToolsCard = $toolsCard
[void](Add-UiLabel $toolsCard 'ПАПКА И ДИАГНОСТИКА' 18 14 360 20 'Muted' 8 -Bold)
[void](Add-UiLabel $toolsCard 'service.bat содержит установку/удаление службы, диагностику, тестирование стратегий и дополнительные инструменты.' 20 42 795 35 'Text' 9)
$openFolderButton = Add-UiButton $toolsCard 'Открыть папку сборки' 20 91 220 40 'secondary'
$openDiagnosticsButton = Add-UiButton $toolsCard 'Служебное меню' 254 91 190 40 'secondary'
$openFolderButton.Add_Click({ Open-ZapretFolder })
$openDiagnosticsButton.Add_Click({ Open-ServiceMenu })

$safetyCard = Add-UiPanel $toolsPage 0 418 844 150 'Card' -Border
$script:SafetyCard = $safetyCard
[void](Add-UiLabel $safetyCard 'ПЕРЕД ИСПОЛЬЗОВАНИЕМ' 18 14 360 20 'Amber' 8 -Bold)
[void](Add-UiLabel $safetyCard '• Запуск требует прав администратора и использует WinDivert из папки bin.' 20 43 795 22 'Text' 9)
[void](Add-UiLabel $safetyCard '• Не запускайте одновременно несколько средств, использующих WinDivert.' 20 72 795 22 'Text' 9)
[void](Add-UiLabel $safetyCard '• Приложение не скачивает и не обновляет исполняемые файлы; стратегии берутся из этой сборки.' 20 101 795 28 'Muted' 9)

function Update-HomeLayout {
    if (-not $script:HomePage) { return }
    $width = $script:HomePage.ClientSize.Width
    $height = $script:HomePage.ClientSize.Height
    if ($width -lt 1 -or $height -lt 1) { return }

    $diameter = [Math]::Min(220, [Math]::Max(190, [int]($width * 0.23)))
    $powerX = [int](($width * 0.47) - ($diameter / 2))
    $script:PowerButton.Location = [System.Drawing.Point]::new($powerX, 82)
    $script:PowerButton.Size = [System.Drawing.Size]::new($diameter, $diameter)
    $script:HomeAutoPickButton.Location = [System.Drawing.Point]::new(($powerX + [int](($diameter - $script:HomeAutoPickButton.Width) / 2)), 311)

    $metricsX = [Math]::Min(($width - 270), [int]($width * 0.72))
    $script:HomeMetricsTitle.Location = [System.Drawing.Point]::new($metricsX, 126)
    $script:HomeStatusDot.Location = [System.Drawing.Point]::new($metricsX, 156)
    $script:HomeStatusLabel.Location = [System.Drawing.Point]::new(($metricsX + 20), 153)
    $script:HomeStatusDetail.Location = [System.Drawing.Point]::new($metricsX, 181)
    $script:HomeStatusDetail.Size = [System.Drawing.Size]::new(255, 22)
    $script:HomeMetricDivider.Location = [System.Drawing.Point]::new($metricsX, 211)
    $script:HomeMetricDivider.Size = [System.Drawing.Size]::new(250, 1)
    $script:HomeStrategyCaption.Location = [System.Drawing.Point]::new($metricsX, 222)
    $script:HomeCurrentStrategyLabel.Location = [System.Drawing.Point]::new($metricsX, 242)
    $script:HomeServiceLabel.Location = [System.Drawing.Point]::new($metricsX, 273)
    $script:HomeServiceLabel.Size = [System.Drawing.Size]::new(260, 42)

    $script:AutoPickProgress.Location = [System.Drawing.Point]::new(0, 348)
    $script:AutoPickProgress.Size = [System.Drawing.Size]::new($width, 5)
    $script:HomeDivider.Location = [System.Drawing.Point]::new(0, 363)
    $script:HomeDivider.Size = [System.Drawing.Size]::new($width, 1)
    $script:HomeLogTitle.Location = [System.Drawing.Point]::new(0, 376)
    $script:ActivityLabel.Location = [System.Drawing.Point]::new(176, 377)
    $script:ActivityLabel.Size = [System.Drawing.Size]::new([Math]::Max(120, ($width - 400)), 20)
    $script:HomeCopyLogButton.Location = [System.Drawing.Point]::new(($width - 202), 371)
    $script:HomeClearLogButton.Location = [System.Drawing.Point]::new(($width - 94), 371)
    $script:ActivityDetailsLabel.Location = [System.Drawing.Point]::new(0, 405)
    $script:ActivityDetailsLabel.Size = [System.Drawing.Size]::new($width, 16)
    $logHeight = [Math]::Max(140, ($height - 455))
    $script:EventLogPanel.Location = [System.Drawing.Point]::new(0, 423)
    $script:EventLogPanel.Size = [System.Drawing.Size]::new($width, $logHeight)
    $script:HomeFooterLabel.Location = [System.Drawing.Point]::new(0, ($height - 24))
    $script:HomeFooterLabel.Size = [System.Drawing.Size]::new($width, 18)
}

function Update-AppLayout {
    if (-not $script:MainForm -or -not $script:ContentHost) { return }
    $clientWidth = $script:MainForm.ClientSize.Width
    $clientHeight = $script:MainForm.ClientSize.Height
    $script:TopBar.Size = [System.Drawing.Size]::new($clientWidth, 64)

    $pillWidth = 138
    $pillX = [Math]::Max(12, ($clientWidth - 20 - $pillWidth))
    $script:TopStatusPill.Location = [System.Drawing.Point]::new($pillX, 15)
    $navWidths = @{ home = 100; strategies = 108; settings = 106; tools = 96 }
    $navGap = 8
    $navTotal = ($navWidths.home + $navWidths.strategies + $navWidths.settings + $navWidths.tools + (3 * $navGap))
    $navX = [Math]::Max(360, ($pillX - 14 - $navTotal))
    foreach ($key in @('home', 'strategies', 'settings', 'tools')) {
        $button = $script:NavButtons[$key]
        $button.Location = [System.Drawing.Point]::new($navX, 12)
        $button.Size = [System.Drawing.Size]::new($navWidths[$key], 40)
        $navX += $navWidths[$key] + $navGap
    }

    $contentWidth = [Math]::Max(720, [Math]::Min(960, ($clientWidth - 48)))
    $contentWidth = [Math]::Min($contentWidth, ($clientWidth - 24))
    $contentX = [int](($clientWidth - $contentWidth) / 2)
    $contentHeight = [Math]::Max(560, ($clientHeight - 92))
    $script:ContentHost.Location = [System.Drawing.Point]::new($contentX, 76)
    $script:ContentHost.Size = [System.Drawing.Size]::new($contentWidth, $contentHeight)

    $pageOffset = [Math]::Max(0, [int](($contentWidth - 844) / 2))
    $script:StrategyPageTitle.Location = [System.Drawing.Point]::new($pageOffset, 0)
    $script:StrategyPageSubtitle.Location = [System.Drawing.Point]::new($pageOffset + 1, 38)
    $script:StrategyListCard.Location = [System.Drawing.Point]::new($pageOffset, 74)
    $script:StrategyDetailsCard.Location = [System.Drawing.Point]::new($pageOffset + 348, 74)

    $script:SettingsPageTitle.Location = [System.Drawing.Point]::new($pageOffset, 0)
    $script:SettingsPageSubtitle.Location = [System.Drawing.Point]::new($pageOffset + 1, 38)
    $script:GameCard.Location = [System.Drawing.Point]::new($pageOffset, 74)
    $script:IpSetCard.Location = [System.Drawing.Point]::new($pageOffset, 287)
    $script:UpdateCard.Location = [System.Drawing.Point]::new($pageOffset, 440)
    $script:SaveSettingsButton.Location = [System.Drawing.Point]::new($pageOffset, 547)
    $script:SettingsNote.Location = [System.Drawing.Point]::new($pageOffset + 220, 550)

    $script:ToolsPageTitle.Location = [System.Drawing.Point]::new($pageOffset, 0)
    $script:ToolsPageSubtitle.Location = [System.Drawing.Point]::new($pageOffset + 1, 38)
    $script:ServiceCard.Location = [System.Drawing.Point]::new($pageOffset, 74)
    $script:ToolsCard.Location = [System.Drawing.Point]::new($pageOffset, 249)
    $script:SafetyCard.Location = [System.Drawing.Point]::new($pageOffset, 418)
    Update-HomeLayout
}

# Инициализация и мониторинг
Update-AppLayout
$form.Add_SizeChanged({ Update-AppLayout })
Set-StrategyIndex 0
Load-SettingsIntoUi
Set-ActivePage 'home'
Add-Activity 'Zapret Manager готов к работе'
Add-Activity ('Доступно стратегий: ' + $script:Strategies.Count)
Refresh-StatusUi

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 2000
$timer.Add_Tick({
    if ($script:LaunchProcess) {
        try {
            if ($script:LaunchProcess.HasExited) {
                $exitCode = $script:LaunchProcess.ExitCode
                $script:LaunchProcess.Dispose()
                $script:LaunchProcess = $null
                if ($exitCode -ne 0) {
                    $tail = @(Read-LaunchLogTail $script:LaunchLogPath)
                    $details = ($tail -join "`r`n")
                    if ([string]::IsNullOrWhiteSpace($details)) { $details = 'Командный файл завершился с кодом ' + $exitCode + '.' }
                    $script:ActivityDetailsLabel.Text = 'Подробности запуска доступны во временном журнале: ' + $script:LaunchLogPath
                    Add-Activity 'BAT-файл завершился с ошибкой'
                    Show-Notice $details 'Не удалось запустить стратегию' ([System.Windows.Forms.MessageBoxIcon]::Error)
                } else {
                    $finishedStatus = Get-CurrentStatus
                    if ($finishedStatus.Running) {
                        Add-Activity 'BAT-файл завершил запуск'
                        $script:ActivityDetailsLabel.Text = 'Исходный BAT-файл завершил настройку. Статус winws.exe обновляется автоматически.'
                    } else {
                        Add-Activity 'BAT-файл завершился, но winws.exe не обнаружен'
                        $script:ActivityDetailsLabel.Text = 'BAT-файл завершился, но winws.exe не найден. Проверьте файлы bin и откройте service.bat → Run Diagnostics.'
                    }
                }
            }
        } catch { $script:LaunchProcess = $null }
    }
    Refresh-StatusUi
})
$timer.Start()

$form.Add_FormClosing({
    param($sender, $eventArgs)
    if ($script:AutoPickWorker -and $script:AutoPickWorker.IsBusy) {
        $script:AutoPickPendingClose = $true
        $script:AutoPickWorker.CancelAsync()
        $eventArgs.Cancel = $true
        $script:ActivityDetailsLabel.Text = 'Завершается текущая проверка и останавливается тестовый winws.exe перед закрытием.'
    }
})
$form.Add_FormClosed({
    $timer.Stop()
    $timer.Dispose()
})

[void]$form.ShowDialog()
