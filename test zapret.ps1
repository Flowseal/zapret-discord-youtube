$hasErrors = $false

# Check Admin
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[ERROR] Запустите от имени администратора!" -ForegroundColor Red
    $hasErrors = $true
} else {
    Write-Host "[OK] Права администратора есть" -ForegroundColor Green
}

# Check curl
if (-not (Get-Command "curl.exe" -ErrorAction SilentlyContinue)) {
    Write-Host "[ERROR] Не найден curl.exe" -ForegroundColor Red
    Write-Host "         Установите curl или добавьте в PATH" -ForegroundColor Yellow
    $hasErrors = $true
} else {
    Write-Host "[OK] Найден curl.exe" -ForegroundColor Green
}

if ($hasErrors) {
    Write-Host ""
    Write-Host "Исправьте ошибки и перезапустите." -ForegroundColor Yellow
    Write-Host "Нажмите любую клавишу для выхода..." -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}

Write-Host ""

$script:spinIndex = -1
$script:currentLine = ""

# Config
$targetDir = $PSScriptRoot
$batFiles = Get-ChildItem -Path $targetDir -Filter "general*.bat" | Sort-Object Name

# Select test mode: all configs or custom subset
function Read-ModeSelection {
    while ($true) {
        Write-Host "" 
        Write-Host "Выберите режим запуска тестов:" -ForegroundColor Cyan
        Write-Host "  [1] Все конфиги" -ForegroundColor Gray
        Write-Host "  [2] Выборочные конфиги" -ForegroundColor Gray
        $choice = Read-Host "Введите 1 или 2"
        switch ($choice) {
            '1' { return 'all' }
            '2' { return 'select' }
            default { Write-Host "Некорректный ввод. Повторите." -ForegroundColor Yellow }
        }
    }
}

function Read-ConfigSelection {
    param([array]$allFiles)

    while ($true) {
        Write-Host "" 
        Write-Host "Доступные конфиги:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $allFiles.Count; $i++) {
            $idx = $i + 1
            Write-Host "  [$idx] $($allFiles[$i].Name)" -ForegroundColor Gray
        }

        $selectionInput = Read-Host "Введите номера через запятую (пример: 1,3,5)"
        $numbers = $selectionInput -split "[,\s]+" | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }
        $valid = $numbers | Where-Object { $_ -ge 1 -and $_ -le $allFiles.Count } | Select-Object -Unique

        if (-not $valid -or $valid.Count -eq 0) {
            Write-Host "Не выбрано ни одного конфига. Повторите ввод." -ForegroundColor Yellow
            continue
        }

        return $valid | ForEach-Object { $allFiles[$_ - 1] }
    }
}

$mode = Read-ModeSelection
if ($mode -eq 'select') {
    $selected = Read-ConfigSelection -allFiles $batFiles
    $batFiles = $selected
}

# Load targets
$targetsFile = Join-Path $targetDir "targets.txt"
$rawTargets = [ordered]@{}
if (Test-Path $targetsFile) {
    Get-Content $targetsFile | ForEach-Object {
        if ($_ -match '^\s*(\w+)\s*=\s*"(.+)"\s*$') {
            $rawTargets[$matches[1]] = $matches[2]
        }
    }
}

# Defaults if targets.txt missing or empty
if ($rawTargets.Count -eq 0) {
    Write-Host "[INFO] targets.txt отсутствует или пуст. Использую значения по умолчанию." -ForegroundColor Gray
    $rawTargets["Discord Main"]           = "https://discord.com"
    $rawTargets["Discord Gateway"]        = "https://gateway.discord.gg"
    $rawTargets["Discord CDN"]            = "https://cdn.discordapp.com"
    $rawTargets["Discord Updates"]        = "https://updates.discord.com"
    $rawTargets["YouTube Web"]            = "https://www.youtube.com"
    $rawTargets["YouTube Short"]          = "https://youtu.be"
    $rawTargets["YouTube Image"]          = "https://i.ytimg.com"
    $rawTargets["YouTube Video Redirect"] = "https://redirector.googlevideo.com"
    $rawTargets["Google Main"]            = "https://www.google.com"
    $rawTargets["Google Gstatic"]         = "https://www.gstatic.com"
    $rawTargets["Cloudflare Web"]         = "https://www.cloudflare.com"
    $rawTargets["Cloudflare CDN"]         = "https://cdnjs.cloudflare.com"
    $rawTargets["Cloudflare DNS 1.1.1.1"] = "PING:1.1.1.1"
    $rawTargets["Cloudflare DNS 1.0.0.1"] = "PING:1.0.0.1"
    $rawTargets["Google DNS 8.8.8.8"]     = "PING:8.8.8.8"
    $rawTargets["Google DNS 8.8.4.4"]     = "PING:8.8.4.4"
    $rawTargets["Quad9 DNS 9.9.9.9"]      = "PING:9.9.9.9"
} else {
    Write-Host "[INFO] Загружено целей: $($rawTargets.Count)" -ForegroundColor Gray
}

# Convert raw targets to structured list (supports PING:ip for ping-only targets)
function Convert-Target {
    param(
        [string]$Name,
        [string]$Value
    )

    if ($Value -like "PING:*") {
        $ping = $Value -replace '^PING:\s*', ''
        $url = $null
        $pingTarget = $ping
    } else {
        $url = $Value
        $pingTarget = $url -replace "^https?://", "" -replace "/.*$", ""
    }

    return [pscustomobject]@{
        Name       = $Name
        Url        = $url
        PingTarget = $pingTarget
    }
}

$targetList = @()
foreach ($key in $rawTargets.Keys) {
    $targetList += Convert-Target -Name $key -Value $rawTargets[$key]
}

# Max name length for aligned output
$maxNameLen = ($targetList | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum
if (-not $maxNameLen -or $maxNameLen -lt 10) { $maxNameLen = 10 }

Write-Host ""
Write-Host "Нажмите любую клавишу для старта..." -ForegroundColor DarkGray
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")

# Stop winws
function Stop-Zapret {
    Get-Process -Name "winws" -ErrorAction SilentlyContinue | Stop-Process -Force
}

# Spinner animation
function Show-Spinner {
    param($delay = 100)
    $spinChars = @('|', '/', '-', '\')
    $script:spinIndex = ($script:spinIndex + 1) % 4
    Write-Host "`r$($script:currentLine)$($spinChars[$script:spinIndex])" -NoNewline
    Start-Sleep -Milliseconds $delay
}

$results = @()

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "              ТЕСТ КОНФИГУРАЦИЙ ZAPRET" -ForegroundColor Cyan
Write-Host "                Всего конфигов: $($batFiles.Count.ToString().PadLeft(2))" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

$configNum = 0
foreach ($file in $batFiles) {
    $configNum++
    Write-Host ""
    Write-Host "------------------------------------------------------------" -ForegroundColor DarkCyan
    Write-Host "  [$configNum/$($batFiles.Count)] $($file.Name)" -ForegroundColor Yellow
    Write-Host "------------------------------------------------------------" -ForegroundColor DarkCyan
    
    # Cleanup
    Stop-Zapret
    
    # Start config
    Write-Host "  > Запуск конфигурации..." -ForegroundColor Cyan
    $proc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$($file.FullName)`"" -WorkingDirectory $targetDir -PassThru -WindowStyle Minimized
    
    # Wait init
    Write-Host "  > Ожидаю запуск (5с)..." -ForegroundColor DarkGray
    Start-Sleep -Seconds 5
    
    # Tests
    Write-Host ""
    
    $currentRes = [ordered]@{
        'Конфиг' = $file.Name
    }

    $curlTimeoutSeconds = 8

    # Parallel target checks
    $targetJobs = @()
    foreach ($target in $targetList) {
        $targetJobs += Start-Job -ScriptBlock {
            param($t, $curlTimeoutSeconds)

            $httpPieces = @()

            if ($t.Url) {
                $tests = @(
                    @{ Label = "HTTP";   Args = @("--http1.1") },
                    # Enforce exact TLS versions by pinning both min and max
                    @{ Label = "TLS1.0"; Args = @("--tlsv1.0", "--tls-max", "1.0") },
                    @{ Label = "TLS1.1"; Args = @("--tlsv1.1", "--tls-max", "1.1") },
                    @{ Label = "TLS1.2"; Args = @("--tlsv1.2", "--tls-max", "1.2") },
                    @{ Label = "TLS1.3"; Args = @("--tlsv1.3", "--tls-max", "1.3") }
                )

                $baseArgs = @("-I", "-s", "-m", $curlTimeoutSeconds, "-o", "NUL", "-w", "%{http_code}")
                foreach ($test in $tests) {
                    try {
                        $curlArgs = $baseArgs + $test.Args
                        $output = & curl.exe @curlArgs $t.Url 2>&1
                        $text = ($output | Out-String).Trim()
                        $unsupported = $text -match "does not support|not supported"
                        if ($unsupported) {
                            $httpPieces += "$($test.Label):UNSUP"
                            continue
                        }

                        $ok = ($LASTEXITCODE -eq 0)
                        if ($ok) {
                            $httpPieces += "$($test.Label):OK   "
                        } else {
                            $httpPieces += "$($test.Label):ERROR"
                        }
                    } catch {
                        $httpPieces += "$($test.Label):ERROR"
                    }
                }
            }

            $pingResult = "н/д"
            if ($t.PingTarget) {
                try {
                    $pings = Test-Connection -ComputerName $t.PingTarget -Count 3 -ErrorAction Stop
                    $avg = ($pings | Measure-Object -Property ResponseTime -Average).Average
                    $pingResult = "{0:N0} ms" -f $avg
                } catch {
                    $pingResult = "Тайм-аут"
                }
            }

            return [pscustomobject]@{
                Name          = $t.Name
                HttpTokens    = $httpPieces
                PingResult    = $pingResult
                IsUrl         = [bool]$t.Url
            }
        } -ArgumentList $target, $curlTimeoutSeconds
    }

    $script:currentLine = "  Выполняю тесты "
    Write-Host "`r$($script:currentLine) " -NoNewline
    while (@($targetJobs | Where-Object State -eq 'Running').Count -gt 0) {
        Show-Spinner 120
    }

    Wait-Job -Job $targetJobs | Out-Null
    $targetResults = foreach ($job in $targetJobs) { Receive-Job -Job $job }
    Remove-Job -Job $targetJobs -Force

    $targetLookup = @{}
    foreach ($res in $targetResults) { $targetLookup[$res.Name] = $res }

    foreach ($target in $targetList) {
        $res = $targetLookup[$target.Name]
        if (-not $res) { continue }

        $padding = " " * 60
        Write-Host "`r$padding" -NoNewline
        Write-Host "`r  $($target.Name.PadRight($maxNameLen))    " -NoNewline

        if ($res.IsUrl -and $res.HttpTokens) {
            foreach ($tok in $res.HttpTokens) {
                $tokColor = "Green"
                if ($tok -match "UNSUP") { $tokColor = "Yellow" }
                elseif ($tok -match "ERR") { $tokColor = "Red" }
                Write-Host " $tok" -NoNewline -ForegroundColor $tokColor
            }
            Write-Host " | Пинг: " -NoNewline -ForegroundColor DarkGray
            if ($res.PingResult -eq "Тайм-аут") {
                $pingColor = "Yellow"
            } else {
                $pingColor = "Cyan"
            }
            Write-Host "$($res.PingResult)" -NoNewline -ForegroundColor $pingColor
            Write-Host ""
        } else {
            # Ping-only target
            Write-Host " Пинг: " -NoNewline -ForegroundColor DarkGray
            if ($res.PingResult -eq "Тайм-аут") {
                $pingColor = "Red"
            } else {
                $pingColor = "Cyan"
            }
            Write-Host "$($res.PingResult)" -ForegroundColor $pingColor
        }

        # Build combined string for CSV
        if ($res.IsUrl -and $res.HttpTokens) {
            $combined = ($res.HttpTokens -join " ") + " | Пинг: $($res.PingResult)"
        } else {
            $combined = "Пинг: $($res.PingResult)"
        }
        $currentRes[$target.Name] = $combined
    }

    $results += [PSCustomObject]$currentRes
    
    # Stop
    Stop-Zapret
    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
}

# Save CSV
$csvPath = Join-Path $PSScriptRoot "test results.csv"
$results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "Результаты сохранены в: " -NoNewline -ForegroundColor DarkGray
Write-Host "test results.csv" -ForegroundColor Cyan
Write-Host ""
Write-Host "Нажмите любую клавишу для выхода..." -ForegroundColor DarkGray
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
