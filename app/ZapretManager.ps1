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
$script:LastRunningState = $null
$script:Status = $null
$script:Pages = @{}
$script:NavButtons = @{}

$script:Palette = @{
    Background = [System.Drawing.ColorTranslator]::FromHtml('#0B1020')
    Sidebar    = [System.Drawing.ColorTranslator]::FromHtml('#0D1424')
    Card       = [System.Drawing.ColorTranslator]::FromHtml('#121B2C')
    CardAlt    = [System.Drawing.ColorTranslator]::FromHtml('#172235')
    Border     = [System.Drawing.ColorTranslator]::FromHtml('#26344B')
    Text       = [System.Drawing.ColorTranslator]::FromHtml('#E7EDF7')
    Muted      = [System.Drawing.ColorTranslator]::FromHtml('#98A6BC')
    Accent     = [System.Drawing.ColorTranslator]::FromHtml('#8B7CFF')
    AccentHover= [System.Drawing.ColorTranslator]::FromHtml('#7666F2')
    Green      = [System.Drawing.ColorTranslator]::FromHtml('#43D9A1')
    Red        = [System.Drawing.ColorTranslator]::FromHtml('#FF7188')
    Amber      = [System.Drawing.ColorTranslator]::FromHtml('#F0BC59')
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
    if ($Border) { $panel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle }
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
    if ($Variant -eq 'primary') {
        $button.BackColor = $script:Palette.Accent
        $button.ForeColor = [System.Drawing.Color]::White
        $button.FlatAppearance.MouseOverBackColor = $script:Palette.AccentHover
        $button.FlatAppearance.MouseDownBackColor = $script:Palette.AccentHover
    } elseif ($Variant -eq 'danger') {
        $button.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#3A1E2A')
        $button.ForeColor = $script:Palette.Red
        $button.FlatAppearance.MouseOverBackColor = [System.Drawing.ColorTranslator]::FromHtml('#482231')
    } elseif ($Variant -eq 'nav') {
        $button.BackColor = $script:Palette.Sidebar
        $button.ForeColor = $script:Palette.Muted
        $button.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
        $button.Padding = [System.Windows.Forms.Padding]::new(14, 0, 0, 0)
        $button.FlatAppearance.MouseOverBackColor = $script:Palette.CardAlt
    } else {
        $button.BackColor = $script:Palette.CardAlt
        $button.ForeColor = $script:Palette.Text
        $button.FlatAppearance.MouseOverBackColor = [System.Drawing.ColorTranslator]::FromHtml('#20304A')
    }
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

function Add-Activity {
    param([string]$Text)
    if ($script:ActivityLabel) {
        $script:ActivityLabel.Text = (Get-Date -Format 'HH:mm:ss') + '  ·  ' + $Text
    }
}

function Set-ActivePage {
    param([string]$Name)
    foreach ($key in $script:Pages.Keys) { $script:Pages[$key].Visible = ($key -eq $Name) }
    foreach ($key in $script:NavButtons.Keys) {
        if ($key -eq $Name) {
            $script:NavButtons[$key].BackColor = $script:Palette.CardAlt
            $script:NavButtons[$key].ForeColor = $script:Palette.Text
        } else {
            $script:NavButtons[$key].BackColor = $script:Palette.Sidebar
            $script:NavButtons[$key].ForeColor = $script:Palette.Muted
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
        if ($script:HomeStrategyCombo.SelectedIndex -ne $Index) { $script:HomeStrategyCombo.SelectedIndex = $Index }
        if ($script:StrategyList.SelectedIndex -ne $Index) { $script:StrategyList.SelectedIndex = $Index }
        $script:StrategyDetailTitle.Text = $script:SelectedStrategy.Title
        $script:StrategyDetailFamily.Text = $script:SelectedStrategy.Family
        $script:StrategyDetailDescription.Text = $script:SelectedStrategy.Description
        $script:StrategyDetailSummary.Text = $script:SelectedStrategy.Summary
        $script:HomeStrategyDescription.Text = $script:SelectedStrategy.Description
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
        $script:HomeStatusDot.BackColor = $script:Palette.Green
        $script:HomeStatusDetail.Text = ('winws.exe из этой папки: {0}; {1}' -f $status.ProcessCount, $serviceNote)
        $script:TopStatusLabel.Text = 'АКТИВНО'
        $script:TopStatusLabel.ForeColor = $script:Palette.Green
        $script:StopButton.Enabled = $true
        $script:StartButton.Enabled = $false
    } elseif ($launchPending) {
        $script:HomeStatusLabel.Text = 'Запуск…'
        $script:HomeStatusLabel.ForeColor = $script:Palette.Amber
        $script:HomeStatusDot.BackColor = $script:Palette.Amber
        $script:HomeStatusDetail.Text = 'Выполняется исходный BAT-файл; ожидание запуска winws.exe.'
        $script:TopStatusLabel.Text = 'ЗАПУСК'
        $script:TopStatusLabel.ForeColor = $script:Palette.Amber
        $script:StopButton.Enabled = $true
        $script:StartButton.Enabled = $false
    } else {
        $script:HomeStatusLabel.Text = 'Не запущено'
        $script:HomeStatusLabel.ForeColor = $script:Palette.Muted
        $script:HomeStatusDot.BackColor = $script:Palette.Border
        $script:HomeStatusDetail.Text = $serviceNote
        $script:TopStatusLabel.Text = 'ОЖИДАНИЕ'
        $script:TopStatusLabel.ForeColor = $script:Palette.Muted
        $script:StopButton.Enabled = $false
        $script:StartButton.Enabled = $true
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

    if ($null -ne $script:LastRunningState -and $script:LastRunningState -ne $status.Running) {
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
        $script:HomeStatusDot.BackColor = $script:Palette.Amber
        $script:TopStatusLabel.Text = 'ЗАПУСК'
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
$form.Text = 'Zapret Manager'
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.Size = [System.Drawing.Size]::new(1160, 760)
$form.MinimumSize = [System.Drawing.Size]::new(1160, 700)
$form.BackColor = $script:Palette.Background
$form.ForeColor = $script:Palette.Text
$form.Font = [System.Drawing.Font]::new('Segoe UI', 9, [System.Drawing.FontStyle]::Regular)
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi

$sidebar = Add-UiPanel $form 0 0 224 $form.ClientSize.Height 'Sidebar'
$sidebar.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
$sidebar.AutoScroll = $true
$brandMark = Add-UiPanel $sidebar 18 24 42 42 'Accent'
$brandMarkLabel = Add-UiLabel $brandMark 'Z' 0 0 42 42 'Text' 19 -Bold -Align ([System.Drawing.ContentAlignment]::MiddleCenter)
$brandMarkLabel.ForeColor = [System.Drawing.Color]::White
[void](Add-UiLabel $sidebar 'ZAPRET' 72 24 130 24 'Text' 15 -Bold)
[void](Add-UiLabel $sidebar 'CONTROL CENTER' 73 47 132 18 'Muted' 8 -Bold)

$script:NavButtons.home = Add-UiButton $sidebar '01   Главная' 14 118 196 44 'nav'
$script:NavButtons.strategies = Add-UiButton $sidebar '02   Стратегии' 14 168 196 44 'nav'
$script:NavButtons.settings = Add-UiButton $sidebar '03   Настройки' 14 218 196 44 'nav'
$script:NavButtons.tools = Add-UiButton $sidebar '04   Службы и помощь' 14 268 196 44 'nav'
$script:NavButtons.home.Add_Click({ Set-ActivePage 'home' })
$script:NavButtons.strategies.Add_Click({ Set-ActivePage 'strategies' })
$script:NavButtons.settings.Add_Click({ Set-ActivePage 'settings' })
$script:NavButtons.tools.Add_Click({ Set-ActivePage 'tools' })
$sidebarLine = Add-UiPanel $sidebar 18 581 188 1 'Border'
[void](Add-UiLabel $sidebar 'ЛОКАЛЬНОЕ ПРИЛОЖЕНИЕ' 18 594 186 20 'Muted' 8 -Bold)
[void](Add-UiLabel $sidebar 'Использует стратегии и файлы zapret из папки этого репозитория.' 18 619 185 52 'Muted' 9)
[void](Add-UiLabel $sidebar 'Требуются права администратора.' 18 684 186 34 'Amber' 8)

$topBar = Add-UiPanel $form 224 0 ($form.ClientSize.Width - 224) 78 'Background'
$topBar.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$script:PageTitleLabel = Add-UiLabel $topBar 'Главная' 24 13 500 30 'Text' 18 -Bold
[void](Add-UiLabel $topBar 'ЛОКАЛЬНЫЙ КОНТРОЛЛЕР ZAPRET' 25 45 400 18 'Muted' 8 -Bold)
$topStatusPill = Add-UiPanel $topBar 790 20 116 34 'CardAlt'
$script:TopStatusLabel = Add-UiLabel $topStatusPill 'ОЖИДАНИЕ' 0 0 116 34 'Muted' 8 -Bold -Align ([System.Drawing.ContentAlignment]::MiddleCenter)
$topStatusPill.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right

$contentHost = Add-UiPanel $form 248 98 ($form.ClientSize.Width - 260) ($form.ClientSize.Height - 98) 'Background'
$contentHost.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right

function New-Page {
    param([string]$Name)
    $page = Add-UiPanel $contentHost 0 0 $contentHost.ClientSize.Width $contentHost.ClientSize.Height 'Background'
    $page.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $page.AutoScroll = $true
    $script:Pages[$Name] = $page
    return $page
}

$homePage = New-Page 'home'
$strategyPage = New-Page 'strategies'
$settingsPage = New-Page 'settings'
$toolsPage = New-Page 'tools'

# Главная
[void](Add-UiLabel $homePage 'Контроль подключения' 0 0 720 34 'Text' 22 -Bold)
[void](Add-UiLabel $homePage 'Выберите стратегию из поставки, запустите её и проверьте статус.' 1 38 820 24 'Muted' 10)
$statusCard = Add-UiPanel $homePage 0 74 844 120 'Card' -Border
[void](Add-UiLabel $statusCard 'СОСТОЯНИЕ ZAPRET' 20 13 240 20 'Muted' 8 -Bold)
$script:HomeStatusDot = Add-UiPanel $statusCard 21 43 10 10 'Border'
$script:HomeStatusLabel = Add-UiLabel $statusCard 'Не запущено' 40 34 260 30 'Muted' 16 -Bold
$script:HomeStatusDetail = Add-UiLabel $statusCard 'Проверка процессов…' 40 66 640 30 'Muted' 9
$refreshButton = Add-UiButton $statusCard 'Обновить' 698 40 124 38 'secondary'
$refreshButton.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$refreshButton.Add_Click({ Refresh-StatusUi; Add-Activity 'Статус обновлён' })

$launchCard = Add-UiPanel $homePage 0 210 844 237 'Card' -Border
[void](Add-UiLabel $launchCard 'БЫСТРЫЙ ЗАПУСК' 20 14 250 20 'Muted' 8 -Bold)
[void](Add-UiLabel $launchCard 'Стратегия' 20 44 240 22 'Text' 10 -Bold)
$script:HomeStrategyCombo = Add-UiComboBox $launchCard 20 70 332 36
foreach ($strategy in $script:Strategies) { [void]$script:HomeStrategyCombo.Items.Add($strategy.Title) }
$script:HomeStrategyDescription = Add-UiLabel $launchCard '' 378 67 420 58 'Muted' 9
[void](Add-UiLabel $launchCard 'Менеджер запускает выбранный general*.bat без изменения его параметров.' 20 119 785 22 'Muted' 8)
$script:StartButton = Add-UiButton $launchCard '▶  Запустить' 20 157 158 44 'primary'
$script:StopButton = Add-UiButton $launchCard '■  Остановить' 190 157 158 44 'danger'
$settingsShortcut = Add-UiButton $launchCard 'Настройки' 360 157 132 44 'secondary'
$script:StartButton.Add_Click({ Start-SelectedStrategy })
$script:StopButton.Add_Click({ Stop-CurrentStrategy })
$settingsShortcut.Add_Click({ Set-ActivePage 'settings' })

$infoCard = Add-UiPanel $homePage 0 450 844 126 'Card' -Border
[void](Add-UiLabel $infoCard 'ВАЖНО' 20 13 140 18 'Amber' 8 -Bold)
[void](Add-UiLabel $infoCard 'Работа зависит от провайдера и текущей сети. Если выбранная стратегия не подходит — остановите её и проверьте другую.' 20 38 795 35 'Text' 9)
[void](Add-UiLabel $infoCard 'WinDivert — системный драйвер из комплекта zapret. Запускайте только проверенную сборку и учитывайте предупреждения антивируса.' 20 79 795 36 'Muted' 9)

$script:ActivityLabel = Add-UiLabel $homePage 'ОЖИДАНИЕ' 0 584 844 18 'Muted' 8 -Bold
$script:ActivityDetailsLabel = Add-UiLabel $homePage 'Для старта нужна распакованная папка сборки с bin\winws.exe и исходными general*.bat.' 0 603 844 18 'Muted' 8

# Стратегии
[void](Add-UiLabel $strategyPage 'Набор стратегий' 0 0 720 34 'Text' 22 -Bold)
[void](Add-UiLabel $strategyPage 'Это готовые BAT-файлы из репозитория; приложение не генерирует и не подменяет параметры.' 1 38 840 24 'Muted' 9)
$strategyListCard = Add-UiPanel $strategyPage 0 74 328 518 'Card' -Border
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
$script:StrategyDetailFamily = Add-UiLabel $strategyDetailsCard 'СТРАТЕГИЯ' 20 18 450 20 'Accent' 8 -Bold
$script:StrategyDetailTitle = Add-UiLabel $strategyDetailsCard 'Стандартная' 20 43 450 38 'Text' 21 -Bold
$script:StrategyDetailDescription = Add-UiLabel $strategyDetailsCard '' 20 91 450 72 'Muted' 9
[void](Add-UiLabel $strategyDetailsCard 'ПАРАМЕТРЫ ИЗ ФАЙЛА' 20 179 450 20 'Muted' 8 -Bold)
$script:StrategyDetailSummary = Add-UiLabel $strategyDetailsCard '' 20 205 450 74 'Text' 9
[void](Add-UiLabel $strategyDetailsCard 'Источник: текущая папка репозитория' 20 305 450 20 'Muted' 8)
$script:ChosenStrategyLabel = Add-UiLabel $strategyDetailsCard 'Выбрано: —' 20 346 450 22 'Muted' 9
$chooseStrategyButton = Add-UiButton $strategyDetailsCard 'Выбрать стратегию' 20 387 210 44 'secondary'
$runChosenButton = Add-UiButton $strategyDetailsCard 'Запустить' 244 387 210 44 'primary'
$chooseStrategyButton.Add_Click({ Set-ActivePage 'home'; Add-Activity ('Выбрана стратегия ' + $script:SelectedStrategy.Title) })
$runChosenButton.Add_Click({ Start-SelectedStrategy })
$script:StrategyList.Add_SelectedIndexChanged({
    if (-not $script:SyncingStrategy -and $script:StrategyList.SelectedIndex -ge 0) {
        Set-StrategyIndex $script:StrategyList.SelectedIndex
    }
})
$script:HomeStrategyCombo.Add_SelectedIndexChanged({
    if (-not $script:SyncingStrategy -and $script:HomeStrategyCombo.SelectedIndex -ge 0) {
        Set-StrategyIndex $script:HomeStrategyCombo.SelectedIndex
    }
})

# Настройки
[void](Add-UiLabel $settingsPage 'Настройки фильтров' 0 0 720 34 'Text' 22 -Bold)
[void](Add-UiLabel $settingsPage 'Изменения сохраняются рядом с исходными списками и применяются при следующем запуске.' 1 38 840 24 'Muted' 9)
$gameCard = Add-UiPanel $settingsPage 0 74 844 197 'Card' -Border
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
[void](Add-UiLabel $ipSetCard 'IPSet Filter' 18 12 350 24 'Text' 12 -Bold)
[void](Add-UiLabel $ipSetCard 'Выберите, какие IP-адреса попадут под фильтры стратегий.' 19 39 770 20 'Muted' 8)
$script:IpSetModeCombo = Add-UiComboBox $ipSetCard 20 72 332 34
foreach ($modeText in @('Использовать список', 'Не фильтровать IP', 'Любой IP')) { [void]$script:IpSetModeCombo.Items.Add($modeText) }
$script:IpSetCurrentLabel = Add-UiLabel $ipSetCard '' 374 75 430 25 'Muted' 8
[void](Add-UiLabel $ipSetCard '«Любой IP» может затронуть сайты и приложения вне списка.' 20 108 780 18 'Amber' 8)

$updateCard = Add-UiPanel $settingsPage 0 440 844 83 'Card' -Border
$script:AutoUpdateCheck = New-Object System.Windows.Forms.CheckBox
$script:AutoUpdateCheck.Text = 'Разрешить фоновую проверку обновлений при запуске стратегии'
$script:AutoUpdateCheck.Location = [System.Drawing.Point]::new(18, 13)
$script:AutoUpdateCheck.Size = [System.Drawing.Size]::new(780, 26)
$script:AutoUpdateCheck.ForeColor = $script:Palette.Text
$script:AutoUpdateCheck.BackColor = [System.Drawing.Color]::Transparent
$script:AutoUpdateCheck.Font = [System.Drawing.Font]::new('Segoe UI', 9, [System.Drawing.FontStyle]::Regular)
[void]$updateCard.Controls.Add($script:AutoUpdateCheck)
[void](Add-UiLabel $updateCard 'Переключатель меняет наличие utils\check_updates.enabled.' 20 43 790 20 'Muted' 8)
$saveSettingsButton = Add-UiButton $settingsPage 'Сохранить настройки' 0 547 204 46 'primary'
$settingsNote = Add-UiLabel $settingsPage 'Настройки не перезапускают winws.exe автоматически.' 220 550 600 40 'Muted' 9
$saveSettingsButton.Add_Click({ Save-SettingsFromUi })

# Службы и помощь
[void](Add-UiLabel $toolsPage 'Службы и диагностика' 0 0 720 34 'Text' 22 -Bold)
[void](Add-UiLabel $toolsPage 'Для расширенного управления используется оригинальный service.bat из сборки.' 1 38 840 24 'Muted' 9)
$serviceCard = Add-UiPanel $toolsPage 0 74 844 158 'Card' -Border
[void](Add-UiLabel $serviceCard 'СЛУЖБА АВТОЗАПУСКА' 18 14 300 20 'Muted' 8 -Bold)
$script:ServiceSummaryLabel = Add-UiLabel $serviceCard 'Проверка статуса…' 20 43 795 48 'Text' 9
$openServiceButton = Add-UiButton $serviceCard 'Открыть service.bat' 20 101 210 40 'primary'
$serviceRefreshButton = Add-UiButton $serviceCard 'Обновить статус' 244 101 178 40 'secondary'
$openServiceButton.Add_Click({ Open-ServiceMenu })
$serviceRefreshButton.Add_Click({ Refresh-StatusUi; Add-Activity 'Статус службы обновлён' })

$toolsCard = Add-UiPanel $toolsPage 0 249 844 152 'Card' -Border
[void](Add-UiLabel $toolsCard 'ПАПКА И ДИАГНОСТИКА' 18 14 360 20 'Muted' 8 -Bold)
[void](Add-UiLabel $toolsCard 'service.bat содержит установку/удаление службы, диагностику, тестирование стратегий и дополнительные инструменты.' 20 42 795 35 'Text' 9)
$openFolderButton = Add-UiButton $toolsCard 'Открыть папку сборки' 20 91 220 40 'secondary'
$openDiagnosticsButton = Add-UiButton $toolsCard 'Служебное меню' 254 91 190 40 'secondary'
$openFolderButton.Add_Click({ Open-ZapretFolder })
$openDiagnosticsButton.Add_Click({ Open-ServiceMenu })

$safetyCard = Add-UiPanel $toolsPage 0 418 844 150 'Card' -Border
[void](Add-UiLabel $safetyCard 'ПЕРЕД ИСПОЛЬЗОВАНИЕМ' 18 14 360 20 'Amber' 8 -Bold)
[void](Add-UiLabel $safetyCard '• Запуск требует прав администратора и использует WinDivert из папки bin.' 20 43 795 22 'Text' 9)
[void](Add-UiLabel $safetyCard '• Не запускайте одновременно несколько средств, использующих WinDivert.' 20 72 795 22 'Text' 9)
[void](Add-UiLabel $safetyCard '• Приложение не скачивает и не обновляет исполняемые файлы; стратегии берутся из этой сборки.' 20 101 795 28 'Muted' 9)

# Инициализация и мониторинг
Set-StrategyIndex 0
Load-SettingsIntoUi
Set-ActivePage 'home'
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

$form.Add_FormClosed({
    $timer.Stop()
    $timer.Dispose()
})

[void]$form.ShowDialog()
