# ============================================================================
# ZAPRET NETWORK ACTIVITY ANALYZER
# ============================================================================
# Скрипт для анализа сетевой активности указанного exe файла
param(
    [Parameter(Mandatory = $true)]
    [string]$ExePath,
    
    [Parameter(Mandatory = $false)]
    [ValidateSet("combined", "fast", "full", "monitoring")]
    [string]$Mode = "combined",
    
    [Parameter(Mandatory = $false)]
    [string]$FlushDNS = "false",
    
    [Parameter(Mandatory = $false)]
    [int]$Duration = 900,
    
    [Parameter(Mandatory = $false)]
    [int]$MonitoringDuration = 900,
    
    [Parameter(Mandatory = $false)]
    [switch]$NoLaunch = $false,

    [Parameter(Mandatory = $false)]
    [switch]$UseNetstat = $true
)

# Конвертируем FlushDNS в boolean
if ($FlushDNS -eq "true" -or $FlushDNS -eq 1 -or $FlushDNS -eq "1") {
    $FlushDNS = $true
}
else {
    $FlushDNS = $false
}

# ============================================================================
# ПЕРЕМЕННЫЕ И КОНСТАНТЫ
# ============================================================================

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

$script:ResultsArray = @()
$script:NetstatArray = @()
$script:DNSCacheArray = @()
$script:ProcessInfo = $null
$script:StartTime = Get-Date

# Цвета для вывода
$Colors = @{
    Header  = "Cyan"
    Success = "Green"
    Warning = "Yellow"
    Error   = "Red"
    Info    = "White"
    Accent  = "Magenta"
}

# ============================================================================
# ФУНКЦИИ ВЫВОДА
# ============================================================================

function Write-Header {
    param([string]$Text)
    Write-Host ""
    Write-Host ("=" * 75) -ForegroundColor $Colors.Header
    Write-Host "  $Text" -ForegroundColor $Colors.Header
    Write-Host ("=" * 75) -ForegroundColor $Colors.Header
    Write-Host ""
}

function Write-Section {
    param([string]$Text)
    Write-Host "  $Text" -ForegroundColor $Colors.Accent
    Write-Host "  $(("─" * ($Text.Length)))" -ForegroundColor $Colors.Accent
    Write-Host ""
}

function Write-Status {
    param(
        [string]$Message,
        [string]$Status = "INFO"
    )
    $color = switch ($Status) {
        "OK" { $Colors.Success }
        "WARN" { $Colors.Warning }
        "ERR" { $Colors.Error }
        default { $Colors.Info }
    }
    
    $icon = switch ($Status) {
        "OK" { "✓" }
        "WARN" { "⚠" }
        "ERR" { "✗" }
        default { "ℹ" }
    }
    
    Write-Host "  $icon $Message" -ForegroundColor $color
}

# ============================================================================
# ФУНКЦИИ ПРОВЕРКИ СИСТЕМ
# ============================================================================

function Test-PSVersion {
    $version = $PSVersionTable.PSVersion.Major
    if ($version -lt 3) {
        Write-Status "PowerShell версия $version. Требуется 3.0 или выше" "ERR"
        exit 1
    }
    Write-Status "PowerShell версия $version - OK" "OK"
}

function Test-AdminRights {
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
    if (-not $isAdmin) {
        Write-Status "Требуются права администратора для полного анализа" "WARN"
    }
    else {
        Write-Status "Права администратора подтверждены" "OK"
    }
    return $isAdmin
}

function Test-NetTCPConnection {
    try {
        $null = Get-NetTCPConnection -OwningProcess 0 -ErrorAction SilentlyContinue | Select-Object -First 1
        Write-Status "Get-NetTCPConnection доступна" "OK"
        return $true
    }
    catch {
        Write-Status "Get-NetTCPConnection не доступна. Требуется Win8+" "ERR"
        return $false
    }
}

function Test-OSVersion {
    $osVersion = [System.Environment]::OSVersion.Version
    $win10Build = [version]"10.0.17763" # Win10 1809+
    
    return $osVersion -ge $win10Build
}

# ============================================================================
# ФУНКЦИИ РАБОТЫ С ФАЙЛАМИ И ПРОЦЕССАМИ
# ============================================================================

function Get-ProcessFromPath {
    param([string]$ExePath)
    
    if (-not (Test-Path $ExePath)) {
        Write-Status "Файл не найден: $ExePath" "ERR"
        return $null
    }
    
    $fileName = [System.IO.Path]::GetFileNameWithoutExtension($ExePath)
    
    # Проверим, запущены ли процессы с таким именем
    $processes = Get-Process -Name $fileName -ErrorAction SilentlyContinue
    
    if ($processes) {
        # Если несколько процессов запущено
        if ($processes -is [System.Array]) {
            Write-Status "Найдено несколько запущенных процессов: $fileName ($($processes.Count) шт.)" "OK"
            Write-Host ""
            Write-Section "Выберите процесс"
            
            for ($i = 0; $i -lt $processes.Count; $i++) {
                $proc = $processes[$i]
                Write-Host "  [$($i+1)] $($proc.ProcessName).exe | PID: $($proc.Id) | Памяти: $([math]::Round($proc.WorkingSet/1MB, 2)) MB | Запущен: $($(Get-Process -Id $proc.Id | Select-Object -ExpandProperty StartTime))" -ForegroundColor $Colors.Info
            }
            
            Write-Host ""
            $choice = $null
            while ($null -eq $choice -or $choice -lt 1 -or $choice -gt $processes.Count) {
                $input = Read-Host "Введите номер процесса (1-$($processes.Count))"
                if ([int]::TryParse($input, [ref]$choice)) {
                    if ($choice -ge 1 -and $choice -le $processes.Count) {
                        break
                    }
                }
                Write-Host "Неверный выбор, попробуйте снова." -ForegroundColor $Colors.Error
            }
            
            $selectedProcess = $processes[$choice - 1]
            Write-Host ""
            Write-Status "Выбран процесс PID: $($selectedProcess.Id)" "OK"
            return $selectedProcess
        }
        else {
            # Один процесс запущен
            Write-Status "Найден запущенный процесс: $($processes.Name) (PID: $($processes.Id))" "OK"
            return $processes
        }
    }
    
    # Если процесс не запущен
    if ($NoLaunch) {
        Write-Status "Процесс не запущен и режим -NoLaunch активен. Выход." "ERR"
        return $null
    }
    
    Write-Status "Процесс не запущен. Необходимо запустить для анализа" "WARN"
    
    try {
        Write-Host ""
        Write-Host "  Запуск $fileName..." -ForegroundColor $Colors.Info
        $process = Start-Process -FilePath $ExePath -PassThru -WindowStyle Normal
        
        # Ждем инициализации процесса
        Start-Sleep -Milliseconds 2000
        
        Write-Status "Процесс запущен (PID: $($process.Id))" "OK"
        return $process
    }
    catch {
        Write-Status "Ошибка запуска процесса: $_" "ERR"
        return $null
    }
}

# ============================================================================
# БЫСТРЫЙ РЕЖИМ: Get-NetTCPConnection
# ============================================================================

function Invoke-FastAnalysis {
    param([int]$ProcessID)
    
    Write-Header "БЫСТРЫЙ АНАЛИЗ (Get-NetTCPConnection)"
    Write-Status "Сбор TCP соединений процесса PID: $ProcessID" "INFO"
    
    try {
        $connections = Get-NetTCPConnection -OwningProcess $ProcessID -ErrorAction SilentlyContinue | 
        Where-Object {
            $_.RemoteAddress -and 
            $_.RemoteAddress -notmatch "^127\." -and
            $_.RemoteAddress -notmatch "^::1$" -and
            $_.State -in @("Established", "TimeWait", "CloseWait", "SynSent")
        }
        
        if (-not $connections) {
            Write-Status "Соединения не найдены" "WARN"
            return @()
        }
        
        if ($connections -is [System.Array]) {
            Write-Status "Найдено соединений: $($connections.Count)" "OK"
        }
        else {
            Write-Status "Найдено соединений: 1" "OK"
            $connections = @($connections)
        }
        
        return $connections
    }
    catch {
        Write-Status "Ошибка при получении соединений: $_" "ERR"
        return @()
    }
}

# ============================================================================
# NETSTAT SNAPSHOT (fallback/additional source)
# ============================================================================

function Invoke-NetstatSnapshot {
    param([int]$ProcessID)

    Write-Header "NETSTAT SNAPSHOT (netstat -ano)"
    Write-Status "Сбор данных netstat для PID: $ProcessID" "INFO"

    $results = @()

    try {
        $netstatOutput = netstat -ano -p tcp 2>$null
        if (-not $netstatOutput) {
            Write-Status "netstat вывода нет" "WARN"
            return @()
        }

        foreach ($line in $netstatOutput) {
            $trimmed = $line.Trim()
            if ($trimmed -notmatch "^TCP") { continue }

            $parts = $trimmed -split "\s+"
            if ($parts.Count -lt 5) { continue }

            $proto = $parts[0]
            $local = $parts[1]
            $remote = $parts[2]
            $state = $parts[3]
            $pidVal = $parts[4]

            if ($pidVal -ne $ProcessID) { continue }

            # remote may be 0.0.0.0:0 in LISTENING; skip non-remote
            if ($remote -eq "0.0.0.0:0" -or $remote -eq "[::]:0") { continue }

            # parse remote endpoint
            $remoteHost = $remote
            $remotePort = $null

            if ($remote -match "^(\[.*\]|[^:]+):(\d+)$") {
                $remoteHost = $Matches[1].Trim("[]")
                $remotePort = [int]$Matches[2]
            }

            $results += [PSCustomObject]@{
                IP    = $remoteHost
                Port  = $remotePort
                State = $state
            }
        }

        if ($results.Count -gt 0) {
            Write-Status "netstat: найдено записей: $($results.Count)" "OK"
        }
        else {
            Write-Status "netstat: записей не найдено" "WARN"
        }
    }
    catch {
        Write-Status "Ошибка netstat: $_" "WARN"
    }

    return $results
}

# ============================================================================
# МОНИТОРИНГ РЕЖИМ: Непрерывное отслеживание соединений
# ============================================================================

function Invoke-MonitoringMode {
    param([int]$ProcessID, [int]$DurationSeconds = 1200)
    
    Write-Header "РЕЖИМ МОНИТОРИНГА (Непрерывное отслеживание)"
    Write-Status "Мониторинг процесса PID: $ProcessID в течение $(([math]::Round($DurationSeconds/60, 1))) минут" "INFO"
    Write-Host ""
    
    $allConnections = @()
    $startTime = Get-Date
    $endTime = $startTime.AddSeconds($DurationSeconds)
    $checkInterval = 3  # Проверка каждые 3 секунды
    
    $iteration = 0
    
    while ((Get-Date) -lt $endTime) {
        $iteration++
        $elapsedSeconds = ((Get-Date) - $startTime).TotalSeconds
        $remainingSeconds = $DurationSeconds - $elapsedSeconds
        $progress = ($elapsedSeconds / $DurationSeconds) * 100
        
        Write-Progress -Activity "Мониторинг сетевой активности" `
            -Status "Осталось: $([math]::Round($remainingSeconds/60, 1)) мин" `
            -PercentComplete $progress `
            -Id 1
        
        # Получить текущие соединения
        try {
            $currentConnections = Get-NetTCPConnection -OwningProcess $ProcessID -ErrorAction SilentlyContinue | 
            Where-Object {
                $_.RemoteAddress -and 
                $_.RemoteAddress -notmatch "^127\." -and
                $_.RemoteAddress -notmatch "^::1$" -and
                $_.State -in @("Established", "TimeWait", "CloseWait", "SynSent")
            }
            
            if ($currentConnections) {
                if ($currentConnections -is [System.Array]) {
                    $allConnections += $currentConnections
                }
                else {
                    $allConnections += @($currentConnections)
                }
            }
        }
        catch {
            # Игнорируем ошибки в цикле
        }
        
        Start-Sleep -Seconds $checkInterval
    }
    
    Write-Progress -Activity "Мониторинг сетевой активности" -Completed -Id 1
    Write-Host ""
    
    if ($allConnections.Count -gt 0) {
        Write-Status "Мониторинг завершен. Собрано соединений: $($allConnections.Count)" "OK"
    }
    else {
        Write-Status "Мониторинг завершен. Соединения не найдены" "WARN"
    }
    
    return $allConnections
}

# ============================================================================
# ПОЛНЫЙ РЕЖИМ: TCP + Pktmon DNS
# ============================================================================

function Invoke-FullAnalysis {
    param([int]$ProcessID)
    
    Write-Header "ПОЛНЫЙ АНАЛИЗ (TCP + Pktmon DNS)"
    
    # Этап 1: Собрать TCP соединения
    Write-Section "Этап 1: Сбор TCP соединений"
    $tcpConnections = Invoke-FastAnalysis -ProcessID $ProcessID
    
    # Этап 2: Запустить Pktmon если поддерживается
    Write-Section "Этап 2: Перехват DNS запросов (Pktmon)"
    
    if (-not (Test-OSVersion)) {
        Write-Status "Pktmon требует Windows 10 (1809+) или Windows 11. Пропускаем." "WARN"
        return $tcpConnections
    }
    
    $isAdmin = Test-AdminRights
    if (-not $isAdmin) {
        Write-Status "Pktmon требует прав администратора. Используем только TCP анализ." "WARN"
        return $tcpConnections
    }
    
    Write-Status "Запуск Pktmon для перехвата DNS..." "INFO"
    
    try {
        # Очистить старые фильтры
        pktmon filter remove -p $ProcessID 2>$null | Out-Null
        
        # Добавить фильтр для процесса (UDP port 53 - DNS)
        pktmon filter add -p $ProcessID -t udp | Out-Null
        
        # Запустить Pktmon
        pktmon start --etw -p $ProcessID 2>$null
        
        Write-Status "Pktmon запущен, сбор данных в течение $Duration секунд..." "OK"
        Start-Sleep -Seconds $Duration
        
        # Остановить Pktmon
        pktmon stop 2>$null | Out-Null
        
        # Получить логи
        $etlFile = "$env:TEMP\PktMon_$ProcessID.etl"
        $csvFile = "$env:TEMP\PktMon_$ProcessID.csv"
        
        pktmon etl2txt $etlFile -o $csvFile 2>$null
        
        if (Test-Path $csvFile) {
            Write-Status "DNS данные успешно получены" "OK"
            
            # Парсим CSV и ищем DNS запросы
            $dnsData = @()
            Get-Content $csvFile | ForEach-Object {
                if ($_ -match "DNS" -or $_ -match "Query") {
                    $dnsData += $_
                }
            }
            
            if ($dnsData.Count -gt 0) {
                Write-Status "DNS запросы найдены: $($dnsData.Count) записей" "OK"
            }
            else {
                Write-Status "DNS запросы не найдены в перехвате" "WARN"
            }
        }
        
        # Очистка
        pktmon filter remove -p $ProcessID 2>$null | Out-Null
        pktmon reset 2>$null | Out-Null
        Remove-Item $etlFile -Force -ErrorAction SilentlyContinue
        Remove-Item $csvFile -Force -ErrorAction SilentlyContinue
        
        Write-Status "Очистка Pktmon завершена" "OK"
        
    }
    catch {
        Write-Status "Ошибка при работе с Pktmon: $_" "WARN"
        pktmon filter remove -p $ProcessID 2>$null | Out-Null
        pktmon reset 2>$null | Out-Null
    }
    
    return $tcpConnections
}

# ============================================================================
# DNS RESOLUTION
# ============================================================================

function Resolve-IPToHostname {
    param([string]$IPAddress)
    
    if (-not $IPAddress) {
        return $null
    }
    
    try {
        $hostEntry = [System.Net.Dns]::GetHostEntry($IPAddress)
        return $hostEntry.HostName
    }
    catch {
        return $null
    }
}

# ============================================================================
# ОБРАБОТКА РЕЗУЛЬТАТОВ
# ============================================================================

function Process-Connections {
    param([array]$Connections)
    
    Write-Section "Обработка и дедупликация результатов"
    
    $uniqueIPs = @{}
    $results = @()
    
    foreach ($conn in $Connections) {
        $ip = $conn.RemoteAddress
        $port = $conn.RemotePort
        $state = $conn.State
        
        $key = "$ip`:$port"
        
        if (-not $uniqueIPs.ContainsKey($key)) {
            $uniqueIPs[$key] = @{
                IP       = $ip
                Port     = $port
                State    = $state
                Hostname = $null
                Count    = 1
            }
        }
        else {
            $uniqueIPs[$key].Count++
        }
    }
    
    Write-Status "Уникальных соединений найдено: $($uniqueIPs.Count)" "OK"
    
    # Парллельный DNS lookup
    Write-Status "Выполнение DNS lookup для IP адресов..." "INFO"
    
    $counter = 0
    foreach ($key in $uniqueIPs.Keys) {
        $counter++
        $item = $uniqueIPs[$key]
        
        Write-Progress -Activity "DNS Lookup" -Status "Обработка $counter/$($uniqueIPs.Count)" -PercentComplete (($counter / $uniqueIPs.Count) * 100)
        
        $hostname = Resolve-IPToHostname -IPAddress $item.IP
        $item.Hostname = $hostname
        
        $results += [PSCustomObject]@{
            IP       = $item.IP
            Port     = $item.Port
            Hostname = if ($hostname) { $hostname } else { "(не разрешено)" }
            State    = $item.State
            Count    = $item.Count
        }
    }
    
    Write-Progress -Activity "DNS Lookup" -Completed
    Write-Host ""
    
    Write-Status "DNS lookup завершен" "OK"
    
    return $results | Sort-Object IP
}

# ============================================================================
# ВЫВОД РЕЗУЛЬТАТОВ
# ============================================================================

function Show-Results {
    param([array]$Results, [PSCustomObject]$ProcessInfo)
    
    Write-Header "РЕЗУЛЬТАТЫ АНАЛИЗА"
    
    # Инфо о процессе
    Write-Section "Информация о процессе"
    Write-Host "  Файл:           $($ProcessInfo.Path)" -ForegroundColor $Colors.Info
    Write-Host "  Имя:            $($ProcessInfo.Name)" -ForegroundColor $Colors.Info
    Write-Host "  PID:            $($ProcessInfo.Id)" -ForegroundColor $Colors.Info
    Write-Host "  Дата анализа:   $(Get-Date -Format 'dd.MM.yyyy HH:mm:ss')" -ForegroundColor $Colors.Info
    Write-Host "  Режим анализа:  $Mode" -ForegroundColor $Colors.Info
    Write-Host ""
    
    if ($Results.Count -eq 0) {
        Write-Status "Соединения не найдены" "WARN"
        return
    }
    
    # Статистика
    Write-Section "Статистика"
    $stats = @{
        "Всего соединений"   = $Results.Count
        "Уникальных IP"      = ($Results | Select-Object -ExpandProperty IP -Unique).Count
        "Уникальных доменов" = ($Results | Where-Object { $_.Hostname -ne "(не разрешено)" } | Select-Object -ExpandProperty Hostname -Unique).Count
        "Успешно разрешено"  = "{0}/{1} ({2}%)" -f @(
            ($Results | Where-Object { $_.Hostname -ne "(не разрешено)" }).Count,
            $Results.Count,
            [math]::Round(($Results | Where-Object { $_.Hostname -ne "(не разрешено)" }).Count / $Results.Count * 100)
        )
    }
    
    foreach ($key in $stats.Keys) {
        Write-Host "  • $key`: $($stats[$key])" -ForegroundColor $Colors.Info
    }
    Write-Host ""
    
    # Таблица результатов
    Write-Section "Детальный список соединений"
    
    $Results | Format-Table -AutoSize @(
        @{Label = "IP адрес"; Expression = { $_.IP }; Width = 15 },
        @{Label = "Порт"; Expression = { $_.Port }; Width = 8 },
        @{Label = "Доменное имя"; Expression = { $_.Hostname }; Width = 40 },
        @{Label = "Статус"; Expression = { $_.State }; Width = 12 },
        @{Label = "Кол-во"; Expression = { $_.Count }; Width = 6 }
    ) | Out-String | ForEach-Object {
        Write-Host "  $_" -ForegroundColor $Colors.Info
    }
    
    Write-Host ""
}

function Save-Results {
    param(
        [array]$Results,
        [PSCustomObject]$ProcessInfo,
        [string]$Mode,
        [bool]$UseNetstat = $false,
        [int]$MonitoringDuration = 0,
        [int]$Duration = 0
    )
    
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $fileName = "analyze_results_$($ProcessInfo.Name)_$timestamp.txt"
    $filePath = Join-Path $PSScriptRoot $fileName
    
    $effectiveDuration = if ($Mode -eq "monitoring") { $MonitoringDuration } else { $Duration }
    $content = @"
═════════════════════════════════════════════════════════════════════════════
АНАЛИЗ СЕТЕВОЙ АКТИВНОСТИ - ПОДРОБНЫЙ ОТЧЕТ
═════════════════════════════════════════════════════════════════════════════

ИНФОРМАЦИЯ О ПРОЦЕССЕ:
  Исполняемый файл: $($ProcessInfo.Path)
  Имя процесса:     $($ProcessInfo.Name)
  PID:              $($ProcessInfo.Id)
  Дата анализа:     $(Get-Date -Format 'dd.MM.yyyy HH:mm:ss UTC')

ПАРАМЕТРЫ АНАЛИЗА:
  Режим анализа:    $Mode
  DNS кеш очищен:   $(if ($FlushDNS) { "Да" } else { "Нет" })
    Время сбора:      $effectiveDuration сек
    Netstat добавлен: $(if ($UseNetstat) { "Да" } else { "Нет" })

═════════════════════════════════════════════════════════════════════════════
РЕЗУЛЬТАТЫ
═════════════════════════════════════════════════════════════════════════════

[IP ADDRESS]       | [PORT] | [HOSTNAME]                           | [STATE]      | [COUNT]
───────────────────┼────────┼──────────────────────────────────────┼──────────────┼─────────
"@
    
    foreach ($result in $Results) {
        $hostname = if ($result.Hostname -eq "(не разрешено)") { "" } else { $result.Hostname }
        $content += "{0,-18} | {1,-6} | {2,-37} | {3,-12} | {4,4}" -f $result.IP, $result.Port, $hostname, $result.State, $result.Count
        $content += "`n"
    }
    
    $content += @"

═════════════════════════════════════════════════════════════════════════════
СТАТИСТИКА
═════════════════════════════════════════════════════════════════════════════

Всего соединений:       $($Results.Count)
Уникальных IP:         $(($Results | Select-Object -ExpandProperty IP -Unique).Count)
Уникальных доменов:    $(($Results | Where-Object { $_.Hostname -ne "(не разрешено)" } | Select-Object -ExpandProperty Hostname -Unique).Count)
Успешно разрешено:     $([math]::Round(($Results | Where-Object { $_.Hostname -ne "(не разрешено)" }).Count / $Results.Count * 100))%

СТАТУСЫ СОЕДИНЕНИЙ:
"@
    
    $stateGroups = $Results | Group-Object -Property State
    foreach ($group in $stateGroups) {
        $content += "  $($group.Name): $($group.Count)`n"
    }
    
    $content += @"

═════════════════════════════════════════════════════════════════════════════
ПОЛНЫЙ СПИСОК IP АДРЕСОВ
═════════════════════════════════════════════════════════════════════════════

"@
    
    $Results | Select-Object -ExpandProperty IP -Unique | Sort-Object | ForEach-Object {
        $content += "$_`n"
    }
    
    $content += @"

═════════════════════════════════════════════════════════════════════════════
ПОЛНЫЙ СПИСОК ДОМЕННЫХ ИМЕН
═════════════════════════════════════════════════════════════════════════════

"@
    
    $Results | Where-Object { $_.Hostname -ne "(не разрешено)" } | Select-Object -ExpandProperty Hostname -Unique | Sort-Object | ForEach-Object {
        $content += "$_`n"
    }
    
    $content += @"

═════════════════════════════════════════════════════════════════════════════
Конец отчета
═════════════════════════════════════════════════════════════════════════════
"@
    
    try {
        $content | Out-File -FilePath $filePath -Encoding UTF8 -Force
        Write-Status "Результаты сохранены в: $filePath" "OK"
        return $filePath
    }
    catch {
        Write-Status "Ошибка при сохранении файла: $_" "ERR"
        return $null
    }
}

# ============================================================================
# MAIN SCRIPT
# ============================================================================

function Main {
    Write-Header "АНАЛИЗ СЕТЕВОЙ АКТИВНОСТИ ZAPRET"
    
    # Проверки
    Write-Section "Проверка системы"
    Test-PSVersion
    $isAdmin = Test-AdminRights
    Test-NetTCPConnection
    
    Write-Host ""
    
    # Получить процесс
    Write-Section "Поиск процесса"
    $process = Get-ProcessFromPath -ExePath $ExePath -NoLaunch:$NoLaunch
    
    if (-not $process) {
        Write-Status "Не удалось получить процесс. Выход." "ERR"
        exit 1
    }
    
    Write-Host ""
    
    # Очистить DNS кеш если требуется
    if ($FlushDNS) {
        Write-Section "Очистка DNS кеша"
        try {
            ipconfig /flushdns | Out-Null
            Write-Status "DNS кеш успешно очищен" "OK"
        }
        catch {
            Write-Status "Ошибка при очистке DNS кеша: $_" "WARN"
        }
        Write-Host ""
    }
    
    # Определить был ли процесс уже запущен
    $processWasRunning = -not $NoLaunch
    
    # Выполнить анализ в зависимости от режима
    if ($Mode -eq "monitoring") {
        Write-Section "Параметры мониторинга"
        Write-Host "  Длительность: $(([math]::Round($MonitoringDuration/60, 1))) минут ($MonitoringDuration сек)" -ForegroundColor $Colors.Info
        Write-Host ""
        
        $connections = Invoke-MonitoringMode -ProcessID $process.Id -DurationSeconds $MonitoringDuration
    }
    elseif ($Mode -eq "full") {
        $connections = Invoke-FullAnalysis -ProcessID $process.Id
    }
    elseif ($Mode -eq "fast") {
        $connections = Invoke-FastAnalysis -ProcessID $process.Id
    }
    else {
        # combined: Get-NetTCPConnection + netstat snapshot
        $connections = Invoke-FastAnalysis -ProcessID $process.Id

        if ($UseNetstat) {
            Write-Host ""
            $netstatConns = Invoke-NetstatSnapshot -ProcessID $process.Id
            if ($netstatConns) {
                $connections += $netstatConns
            }
        }
    }
    
    Write-Host ""
    
    # Обработать результаты
    if ($connections.Count -gt 0) {
        $results = Process-Connections -Connections $connections
        
        # Показать результаты
        Show-Results -Results $results -ProcessInfo $process
        
        # Сохранить результаты
        Write-Section "Сохранение результатов"
        $savedPath = Save-Results -Results $results -ProcessInfo $process -Mode $Mode -UseNetstat:$UseNetstat -MonitoringDuration $MonitoringDuration -Duration $Duration
    }
    else {
        Write-Status "Соединения не найдены для анализа" "WARN"
    }
    
    Write-Host ""
    Write-Header "АНАЛИЗ ЗАВЕРШЕН"
}

# Запуск главной функции
Main
