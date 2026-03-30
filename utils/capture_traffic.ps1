# Скрипт для захвата сетевого трафика Endfield с помощью netsh
# Использование: .\capture_traffic.ps1 -Mode [vpn|novpn]

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("vpn", "novpn")]
    [string]$Mode,
    
    [int]$Duration = 60
)

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$capturePath = "$PSScriptRoot\..\asdasd\endfield_${Mode}_${timestamp}.etl"

Write-Host "🔍 ДИАГНОСТИКА ПОДКЛЮЧЕНИЯ ENDFIELD" -ForegroundColor Cyan
Write-Host "=" * 60
Write-Host "Режим: $Mode" -ForegroundColor Yellow
Write-Host "Длительность: $Duration секунд" -ForegroundColor Yellow
Write-Host "Файл: $capturePath" -ForegroundColor Yellow
Write-Host "=" * 60
Write-Host ""

# Проверка прав администратора
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "❌ Требуются права администратора!" -ForegroundColor Red
    Write-Host "   Запустите PowerShell от имени администратора" -ForegroundColor Yellow
    exit 1
}

Write-Host "📋 ИНСТРУКЦИИ:" -ForegroundColor Green
Write-Host ""
if ($Mode -eq "vpn") {
    Write-Host "  1. ВКЛЮЧИТЕ VPN" -ForegroundColor Yellow
    Write-Host "  2. Дождитесь сообщения о начале захвата" -ForegroundColor Yellow
    Write-Host "  3. ЗАПУСТИТЕ ИГРУ Endfield" -ForegroundColor Yellow
    Write-Host "  4. Подождите полной загрузки (попробуйте войти в игру)" -ForegroundColor Yellow
}
else {
    Write-Host "  1. ВЫКЛЮЧИТЕ VPN" -ForegroundColor Yellow
    Write-Host "  2. Дождитесь сообщения о начале захвата" -ForegroundColor Yellow
    Write-Host "  3. ЗАПУСТИТЕ ИГРУ Endfield" -ForegroundColor Yellow
    Write-Host "  4. Попробуйте подключиться (будет ошибка - это нормально)" -ForegroundColor Yellow
}
Write-Host ""
Write-Host "Нажмите любую клавишу когда будете готовы..." -ForegroundColor Cyan
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
Write-Host ""

# Запуск захвата
Write-Host "🎬 Начинаю захват пакетов..." -ForegroundColor Green
try {
    # Останавливаем предыдущий захват если есть
    netsh trace stop 2>$null | Out-Null
    
    # Запускаем новый захват
    # Фильтруем только IPv4, чтобы уменьшить размер
    $null = netsh trace start capture=yes tracefile="$capturePath" maxsize=500 filemode=circular overwrite=yes
    
    if ($LASTEXITCODE -ne 0) {
        throw "Не удалось запустить захват"
    }
    
    Write-Host "✅ Захват начат!" -ForegroundColor Green
    Write-Host ""
    Write-Host "⏱️  Захватываю пакеты $Duration секунд..." -ForegroundColor Yellow
    Write-Host ""
    
    # Показываем прогресс
    for ($i = 1; $i -le $Duration; $i++) {
        $percent = [math]::Round(($i / $Duration) * 100)
        Write-Progress -Activity "Захват трафика" -Status "$i из $Duration секунд ($percent%)" -PercentComplete $percent
        Start-Sleep -Seconds 1
    }
    
    Write-Progress -Activity "Захват трафика" -Completed
    
}
catch {
    Write-Host "❌ Ошибка: $_" -ForegroundColor Red
    exit 1
}

# Останавливаем захват
Write-Host ""
Write-Host "🛑 Останавливаю захват..." -ForegroundColor Yellow
netsh trace stop | Out-Null

Write-Host ""
Write-Host "✅ ЗАХВАТ ЗАВЕРШЕН!" -ForegroundColor Green
Write-Host "   Файл сохранен: $capturePath" -ForegroundColor Cyan
Write-Host ""

# Пытаемся конвертировать в CAP формат
$capPath = $capturePath -replace '\.etl$', '.cap'
Write-Host "🔄 Попытка конвертации в CAP формат..." -ForegroundColor Yellow

# Проверяем наличие etl2pcapng (часть Microsoft Message Analyzer)
$etl2pcapng = "C:\Program Files\Microsoft Message Analyzer\etl2pcapng.exe"
if (Test-Path $etl2pcapng) {
    try {
        & $etl2pcapng $capturePath $capPath
        Write-Host "✅ Конвертировано в: $capPath" -ForegroundColor Green
    }
    catch {
        Write-Host "⚠️  Не удалось конвертировать (не критично)" -ForegroundColor Yellow
    }
}
else {
    Write-Host "ℹ️  etl2pcapng не найден, используем ETL файл" -ForegroundColor Cyan
}

Write-Host ""
Write-Host "📊 СЛЕДУЮЩИЙ ШАГ:" -ForegroundColor Green
Write-Host "   Повторите процесс для другого режима (vpn/novpn)" -ForegroundColor Yellow
Write-Host "   Затем запустите: .\compare_traffic.py" -ForegroundColor Yellow
Write-Host ""
