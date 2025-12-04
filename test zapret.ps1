$hasErrors = $false

# Check Admin
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[ERROR] Run as Administrator!" -ForegroundColor Red
    $hasErrors = $true
} else {
    Write-Host "[OK] Admin rights" -ForegroundColor Green
}

# Check curl
$curlPath = Get-Command "curl.exe" -ErrorAction SilentlyContinue
if (-not $curlPath) {
    Write-Host "[ERROR] curl.exe not found!" -ForegroundColor Red
    Write-Host "         Install curl or add to PATH" -ForegroundColor Yellow
    $hasErrors = $true
} else {
    Write-Host "[OK] curl.exe found" -ForegroundColor Green
}

if ($hasErrors) {
    Write-Host ""
    Write-Host "Fix errors and restart." -ForegroundColor Yellow
    Write-Host "Press any key to exit..." -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}

Write-Host ""

# Config
$targetDir = $PSScriptRoot
$batFiles = Get-ChildItem -Path $targetDir -Filter "general*.bat" | Sort-Object Name

# Load targets
$targetsFile = Join-Path $targetDir "targets.txt"
$targets = [ordered]@{}
if (Test-Path $targetsFile) {
    Get-Content $targetsFile | ForEach-Object {
        if ($_ -match '^\s*(\w+)\s*=\s*"(.+)"\s*$') {
            $targets[$matches[1]] = $matches[2]
        }
    }
}

# Defaults if empty
if ($targets.Count -eq 0) {
    Write-Host "[INFO] targets.txt missing or empty. Using defaults." -ForegroundColor Gray
    $targets["Discord"] = "https://discord.com"
    $targets["YouTube"] = "https://www.youtube.com"
} else {
    Write-Host "[INFO] Loaded targets: $($targets.Count)" -ForegroundColor Gray
}

Write-Host ""
Write-Host "Press any key to start..." -ForegroundColor DarkGray
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")

# Stop winws
function Stop-Zapret {
    Get-Process -Name "winws" -ErrorAction SilentlyContinue | Stop-Process -Force
}

# Curl check
function Test-Curl {
    param($url)
    try {
        $output = & curl.exe -I -s -m 5 -o NUL -w "%{http_code}" $url
        
        if ($LASTEXITCODE -eq 0 -and $output -match "^2\d\d|^3\d\d") {
            return "OK ($output)"
        } else {
            return "ERROR ($output)"
        }
    } catch {
        return "ERROR (Exception)"
    }
}

# Ping check
function Test-Ping {
    param($target)
    try {
        $pings = Test-Connection -ComputerName $target -Count 3 -ErrorAction Stop
        $avg = ($pings | Measure-Object -Property ResponseTime -Average).Average
        return "{0:N0} ms" -f $avg
    } catch {
        return "Timeout"
    }
}

# Spinner animation
function Show-Spinner {
    param($delay = 100)
    $spinChars = @('|', '/', '-', '\')
    $script:spinIndex = ($script:spinIndex + 1) % 4
    Write-Host "`r$($script:currentLine)$($spinChars[$script:spinIndex])" -NoNewline
    Start-Sleep -Milliseconds $delay
}

# Curl with progress
function Test-CurlWithProgress {
    param($url, $label)
    
    $job = Start-Job -ScriptBlock {
        param($u)
        $output = & curl.exe -I -s -m 10 -o NUL -w "%{http_code}" $u
        if ($LASTEXITCODE -eq 0 -and $output -match "^2\d\d|^3\d\d") {
            return "OK ($output)"
        } else {
            return "ERROR ($output)"
        }
    } -ArgumentList $url
    
    $script:currentLine = "  $label [HTTP] "
    Write-Host "`r$($script:currentLine) " -NoNewline
    while ($job.State -eq 'Running') {
        Show-Spinner
    }
    
    $result = Receive-Job -Job $job
    Remove-Job -Job $job
    
    if (-not $result) { return "ERROR" }
    return $result
}

# Ping with progress
function Test-PingWithProgress {
    param($target, $label)
    
    $job = Start-Job -ScriptBlock {
        param($t)
        try {
            $pings = Test-Connection -ComputerName $t -Count 3 -ErrorAction Stop
            $avg = ($pings | Measure-Object -Property ResponseTime -Average).Average
            return "{0:N0} ms" -f $avg
        } catch {
            return "Timeout"
        }
    } -ArgumentList $target
    
    $script:currentLine = "  $label [PING] "
    Write-Host "`r$($script:currentLine) " -NoNewline
    while ($job.State -eq 'Running') {
        Show-Spinner
    }
    
    $result = Receive-Job -Job $job
    Remove-Job -Job $job
    
    if (-not $result) { return "Timeout" }
    return $result
}

$results = @()

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "             ZAPRET CONFIGURATION TESTER" -ForegroundColor Cyan
Write-Host "                Total configs: $($batFiles.Count.ToString().PadLeft(2))" -ForegroundColor Cyan
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
    Write-Host "  > Starting config..." -ForegroundColor Cyan
    $proc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$($file.FullName)`"" -WorkingDirectory $targetDir -PassThru -WindowStyle Minimized
    
    # Wait init
    Write-Host "  > Waiting for init (5s)..." -ForegroundColor DarkGray
    Start-Sleep -Seconds 5
    
    # Tests
    Write-Host ""
    
    $currentRes = [ordered]@{
        'Config' = $file.Name
    }

    # Max name length
    $maxNameLen = ($targets.Keys | Measure-Object -Property Length -Maximum).Maximum
    if ($maxNameLen -lt 10) { $maxNameLen = 10 }

    # Dynamic targets
    foreach ($targetName in $targets.Keys) {
        $targetUrl = $targets[$targetName]
        $targetDomain = $targetUrl -replace "^https?://", "" -replace "/.*$", ""
        
        $status = Test-CurlWithProgress $targetUrl $targetName
        
        if ($status -match "OK") {
            $ping = Test-PingWithProgress $targetDomain $targetName
        } else {
            $ping = "?"
        }
        
        if ($status -match "OK") {
            $combined = "$status | Ping: $ping"
            $combinedColor = "Green"
        } else {
            $combined = $status
            $combinedColor = "Red"
        }
        
        $padding = " " * 60
        Write-Host "`r$padding" -NoNewline
        Write-Host "`r  $($targetName.PadRight($maxNameLen))    " -NoNewline
        Write-Host "$combined" -ForegroundColor $combinedColor
        
        $currentRes[$targetName] = $combined
    }

    # Google DNS
    $ping8888 = Test-PingWithProgress "8.8.8.8" "Google DNS"
    $dnsResult = "Ping: $ping8888"
    
    $padding = " " * 60
    Write-Host "`r$padding" -NoNewline
    Write-Host "`r  $("Google DNS".PadRight($maxNameLen))    " -NoNewline
    if ($ping8888 -eq "Timeout") {
        Write-Host "$dnsResult" -ForegroundColor Red
    } else {
        Write-Host "$dnsResult" -ForegroundColor Cyan
    }
    $currentRes['GoogleDNS'] = $dnsResult
    
    $results += [PSCustomObject]$currentRes
    
    # Stop
    Stop-Zapret
    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
}

# Save CSV
$csvPath = Join-Path $PSScriptRoot "test results.csv"
$results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "Results saved to: " -NoNewline -ForegroundColor DarkGray
Write-Host "test results.csv" -ForegroundColor Cyan
Write-Host ""
Write-Host "Press any key to exit..." -ForegroundColor DarkGray
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
