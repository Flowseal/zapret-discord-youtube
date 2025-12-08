$hasErrors = $false

function New-OrderedDict { New-Object System.Collections.Specialized.OrderedDictionary }
function Add-OrSet {
    param($dict, $key, $val)
    if ($dict.Contains($key)) { $dict[$key] = $val } else { $dict.Add($key, $val) }
}
function ConvertTo-PSObject {
    param($dict)
    $props = @{}
    foreach ($k in $dict.Keys) { $props[$k] = $dict[$k] }
    New-Object PSObject -Property $props
}

function Test-ZapretServiceConflict {
    return [bool](Get-Service -Name "zapret" -ErrorAction SilentlyContinue)
}

# Check Admin
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[ERROR] Run as Administrator to execute tests" -ForegroundColor Red
    $hasErrors = $true
} else {
    Write-Host "[OK] Administrator rights detected" -ForegroundColor Green
}

# Check curl
if (-not (Get-Command "curl.exe" -ErrorAction SilentlyContinue)) {
    Write-Host "[ERROR] curl.exe not found" -ForegroundColor Red
    Write-Host "Install curl or add it to PATH" -ForegroundColor Yellow
    $hasErrors = $true
} else {
    Write-Host "[OK] curl.exe found" -ForegroundColor Green
}

# Check if zapret service installed
if (Test-ZapretServiceConflict) {
    Write-Host "[ERROR] Windows service 'zapret' is installed" -ForegroundColor Red
    Write-Host "         Remove the service before running tests" -ForegroundColor Yellow
    Write-Host "         Open service.bat and choose 'Remove Services'" -ForegroundColor Yellow
    $hasErrors = $true
}

if ($hasErrors) {
    Write-Host ""
    Write-Host "Fix the errors above and rerun." -ForegroundColor Yellow
    exit 1
}

$script:spinIndex = -1
$script:currentLine = ""

# Config
$targetDir = $PSScriptRoot
if (-not $targetDir) { $targetDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$batFiles = Get-ChildItem -Path $targetDir -Filter "general*.bat" | Sort-Object Name

# Load targets before choosing mode
$targetsFile = Join-Path $targetDir "targets.txt"
$rawTargets = New-OrderedDict
if (Test-Path $targetsFile) {
    Get-Content $targetsFile | ForEach-Object {
        if ($_ -match '^\s*(\w+)\s*=\s*"(.+)"\s*$') {
            Add-OrSet -dict $rawTargets -key $matches[1] -val $matches[2]
        }
    }
}

# Defaults if targets.txt missing or empty
if ($rawTargets.Count -eq 0) {
    Write-Host "[INFO] targets.txt missing or empty. Using defaults." -ForegroundColor Gray
    Add-OrSet $rawTargets "Discord Main"           "https://discord.com"
    Add-OrSet $rawTargets "Discord Gateway"        "https://gateway.discord.gg"
    Add-OrSet $rawTargets "Discord CDN"            "https://cdn.discordapp.com"
    Add-OrSet $rawTargets "Discord Updates"        "https://updates.discord.com"
    Add-OrSet $rawTargets "YouTube Web"            "https://www.youtube.com"
    Add-OrSet $rawTargets "YouTube Short"          "https://youtu.be"
    Add-OrSet $rawTargets "YouTube Image"          "https://i.ytimg.com"
    Add-OrSet $rawTargets "YouTube Video Redirect" "https://redirector.googlevideo.com"
    Add-OrSet $rawTargets "Google Main"            "https://www.google.com"
    Add-OrSet $rawTargets "Google Gstatic"         "https://www.gstatic.com"
    Add-OrSet $rawTargets "Cloudflare Web"         "https://www.cloudflare.com"
    Add-OrSet $rawTargets "Cloudflare CDN"         "https://cdnjs.cloudflare.com"
    Add-OrSet $rawTargets "Cloudflare DNS 1.1.1.1" "PING:1.1.1.1"
    Add-OrSet $rawTargets "Cloudflare DNS 1.0.0.1" "PING:1.0.0.1"
    Add-OrSet $rawTargets "Google DNS 8.8.8.8"     "PING:8.8.8.8"
    Add-OrSet $rawTargets "Google DNS 8.8.4.4"     "PING:8.8.4.4"
    Add-OrSet $rawTargets "Quad9 DNS 9.9.9.9"      "PING:9.9.9.9"
} else {
    Write-Host "[INFO] Targets loaded: $($rawTargets.Count)" -ForegroundColor Gray
}

Write-Host ""

# Select test mode: all configs or custom subset
function Read-ModeSelection {
    while ($true) {
        Write-Host "Select test run mode:" -ForegroundColor Cyan
        Write-Host "  [1] All configs" -ForegroundColor Gray
        Write-Host "  [2] Selected configs" -ForegroundColor Gray
        $choice = Read-Host "Enter 1 or 2"
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
        Write-Host "Available configs:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $allFiles.Count; $i++) {
            $idx = $i + 1
            Write-Host "  [$idx] $($allFiles[$i].Name)" -ForegroundColor Gray
        }

        $selectionInput = Read-Host "Enter numbers separated by comma (e.g. 1,3,5) or '0' to run all"
        $trimmed = $selectionInput.Trim()
        if ($trimmed -eq '0') {
            return $allFiles
        }

        $numbers = $selectionInput -split "[\,\s]+" | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }
        $valid = $numbers | Where-Object { $_ -ge 1 -and $_ -le $allFiles.Count } | Select-Object -Unique

        if (-not $valid -or $valid.Count -eq 0) {
            Write-Host ""
            Write-Host "No configs selected. Try again." -ForegroundColor Yellow
            continue
        }

        return $valid | ForEach-Object { $allFiles[$_ - 1] }
    }
}

$mode = Read-ModeSelection
if ($mode -eq 'select') {
    $selected = Read-ConfigSelection -allFiles $batFiles
    $batFiles = @($selected)
}

# Ensure we have configs to run
if (-not $batFiles -or $batFiles.Count -eq 0) {
    Write-Host "[ERROR] No general*.bat files found" -ForegroundColor Red
    exit 1
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

    return (New-Object PSObject -Property @{
        Name       = $Name
        Url        = $url
        PingTarget = $pingTarget
    })
}

$targetList = @()
foreach ($key in $rawTargets.Keys) {
    $targetList += Convert-Target -Name $key -Value $rawTargets[$key]
}

# Max name length for aligned output
$maxNameLen = ($targetList | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum
if (-not $maxNameLen -or $maxNameLen -lt 10) { $maxNameLen = 10 }

Write-Host ""

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

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "                 ZAPRET CONFIG TESTS" -ForegroundColor Cyan
Write-Host "                 Total configs: $($batFiles.Count.ToString().PadLeft(2))" -ForegroundColor Cyan
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
    Start-Sleep -Seconds 5
    
    # Tests
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

            $pingResult = "n/a"
            if ($t.PingTarget) {
                try {
                    $pings = Test-Connection -ComputerName $t.PingTarget -Count 3 -ErrorAction Stop
                    $avg = ($pings | Measure-Object -Property ResponseTime -Average).Average
                    $pingResult = "{0:N0} ms" -f $avg
                } catch {
                    $pingResult = "Timeout"
                }
            }

            return (New-Object PSObject -Property @{
                Name       = $t.Name
                HttpTokens = $httpPieces
                PingResult = $pingResult
                IsUrl      = [bool]$t.Url
            })
        } -ArgumentList $target, $curlTimeoutSeconds
    }

    $script:currentLine = "  > Running tests..."
    Write-Host $script:currentLine -ForegroundColor DarkGray
    Wait-Job -Job $targetJobs | Out-Null

    Wait-Job -Job $targetJobs | Out-Null
    $targetResults = foreach ($job in $targetJobs) { Receive-Job -Job $job }
    Remove-Job -Job $targetJobs -Force -ErrorAction SilentlyContinue

    $targetLookup = @{}
    foreach ($res in $targetResults) { $targetLookup[$res.Name] = $res }

    foreach ($target in $targetList) {
        $res = $targetLookup[$target.Name]
        if (-not $res) { continue }

        Write-Host "  $($target.Name.PadRight($maxNameLen))    " -NoNewline

        if ($res.IsUrl -and $res.HttpTokens) {
            foreach ($tok in $res.HttpTokens) {
                $tokColor = "Green"
                if ($tok -match "UNSUP") { $tokColor = "Yellow" }
                elseif ($tok -match "ERR") { $tokColor = "Red" }
                Write-Host " $tok" -NoNewline -ForegroundColor $tokColor
            }
            Write-Host " | Ping: " -NoNewline -ForegroundColor DarkGray
            if ($res.PingResult -eq "Timeout") {
                $pingColor = "Yellow"
            } else {
                $pingColor = "Cyan"
            }
            Write-Host "$($res.PingResult)" -NoNewline -ForegroundColor $pingColor
            Write-Host ""
        } else {
            # Ping-only target
            Write-Host " Ping: " -NoNewline -ForegroundColor DarkGray
            if ($res.PingResult -eq "Timeout") {
                $pingColor = "Red"
            } else {
                $pingColor = "Cyan"
            }
            Write-Host "$($res.PingResult)" -ForegroundColor $pingColor
        }

    }
    
    # Stop
    Stop-Zapret
    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
}

Write-Host ""
Write-Host "All tests finished." -ForegroundColor Green



