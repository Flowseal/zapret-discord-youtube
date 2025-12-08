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

# Get ping result (avg) in 'NN ms' format; fallback to ping.exe when Test-Connection absent
function Get-PingAverage {
    param([string]$TargetHost)
    try {
        if (Get-Command Test-Connection -ErrorAction SilentlyContinue) {
            $pings = Test-Connection -ComputerName $TargetHost -Count 3 -ErrorAction Stop
            $avg = ($pings | Measure-Object -Property ResponseTime -Average).Average
            return "{0:N0} ms" -f $avg
        } else {
            $out = & ping.exe -n 3 $TargetHost 2>&1
            $s = ($out | Out-String)
            if ($s -match "Average\s*=\s*(\d+)\s*ms") { return "$($matches[1]) ms" }
            if ($s -match "Average\s*=\s*(\d+)\s*мс") { return "$($matches[1]) ms" }
            if ($s -match "Среднее\s*=\s*(\d+)\s*мс") { return "$($matches[1]) ms" }
            return "Timeout"
        }
    } catch { return "Timeout" }
}

# Safe write helper to avoid "Win32 internal error" when console is not available or a host
function SafeWrite {
    param(
        [string]$Text,
        [string]$Color = $null,
        [switch]$NoNewline
    )
    try {
        if ($Color) {
            if ($NoNewline) { Write-Host -NoNewline $Text -ForegroundColor $Color } else { Write-Host $Text -ForegroundColor $Color }
        } else {
            if ($NoNewline) { Write-Host -NoNewline $Text } else { Write-Host $Text }
        }
    } catch {
        # fallback to Write-Output if host write fails
        if ($NoNewline) { Write-Output -NoNewline $Text } else { Write-Output $Text }
    }
}

# Check Admin
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    SafeWrite "[ERROR] Run as Administrator to execute tests" Red
    $hasErrors = $true
} else {
    SafeWrite "[OK] Administrator rights detected" Green
}

# Check curl
if (-not (Get-Command "curl.exe" -ErrorAction SilentlyContinue)) {
    SafeWrite "[ERROR] curl.exe not found" Red
    SafeWrite "Install curl or add it to PATH" Yellow
    $hasErrors = $true
} else {
    SafeWrite "[OK] curl.exe found" Green
}

# Check if zapret service installed
if (Test-ZapretServiceConflict) {
    SafeWrite "[ERROR] Windows service 'zapret' is installed" Red
    SafeWrite "         Remove the service before running tests" Yellow
    SafeWrite "         Open service.bat and choose 'Remove Services'" Yellow
    $hasErrors = $true
}

if ($hasErrors) {
    SafeWrite ""
    SafeWrite "Fix the errors above and rerun." Yellow
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
    SafeWrite "[INFO] targets.txt missing or empty. Using defaults." Gray
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
    SafeWrite "[INFO] Targets loaded: $($rawTargets.Count)" Gray
}

SafeWrite ""

# Select test mode: all configs or custom subset
function Read-ModeSelection {
    while ($true) {
        SafeWrite "Select test run mode:" Cyan
        SafeWrite "  [1] All configs" Gray
        SafeWrite "  [2] Selected configs" Gray
        $choice = Read-Host "Enter 1 or 2"
        switch ($choice) {
            '1' { return 'all' }
            '2' { return 'select' }
            default { SafeWrite "Invalid input. Try again." Yellow }
        }
    }
}

function Read-ConfigSelection {
    param([array]$allFiles)

    while ($true) {
        SafeWrite "" 
        SafeWrite "Available configs:" Cyan
        for ($i = 0; $i -lt $allFiles.Count; $i++) {
            $idx = $i + 1
            SafeWrite "  [$idx] $($allFiles[$i].Name)" Gray
        }

        $selectionInput = Read-Host "Enter numbers separated by comma (e.g. 1,3,5) or '0' to run all"
        $trimmed = $selectionInput.Trim()
        if ($trimmed -eq '0') {
            return $allFiles
        }

        $numbers = $selectionInput -split "[\,\s]+" | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }
        $valid = $numbers | Where-Object { $_ -ge 1 -and $_ -le $allFiles.Count } | Select-Object -Unique

        if (-not $valid -or $valid.Count -eq 0) {
            SafeWrite ""
            SafeWrite "No configs selected. Try again." Yellow
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
    SafeWrite "[ERROR] No general*.bat files found" Red
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

SafeWrite ""

# Stop winws
function Stop-Zapret {
    Get-Process -Name "winws" -ErrorAction SilentlyContinue | Stop-Process -Force
}

# Spinner animation
function Show-Spinner {
    param($delay = 100)
    $spinChars = @('|', '/', '-', '\')
    $script:spinIndex = ($script:spinIndex + 1) % 4
    SafeWrite "`r$($script:currentLine)$($spinChars[$script:spinIndex])" -NoNewline
    Start-Sleep -Milliseconds $delay
}

SafeWrite ""
SafeWrite "============================================================" Cyan
SafeWrite "                 ZAPRET CONFIG TESTS" Cyan
SafeWrite "                 Total configs: $($batFiles.Count.ToString().PadLeft(2))" Cyan
SafeWrite "============================================================" Cyan

$configNum = 0
foreach ($file in $batFiles) {
    $configNum++
    SafeWrite ""
    SafeWrite "------------------------------------------------------------" DarkCyan
    SafeWrite "  [$configNum/$($batFiles.Count)] $($file.Name)" Yellow
    SafeWrite "------------------------------------------------------------" DarkCyan
    
    # Cleanup
    Stop-Zapret
    
    # Start config
    SafeWrite "  > Starting config..." Cyan
    $proc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$($file.FullName)`"" -WorkingDirectory $targetDir -PassThru -WindowStyle Minimized
    
    # Wait init
    Start-Sleep -Seconds 5
    
    # Tests
    $curlTimeoutSeconds = 8

    # Parallel target checks (Start-Job fallback to sequential)
    $canJob = $false
    try { $canJob = (Get-Command Start-Job -ErrorAction SilentlyContinue) -ne $null } catch { $canJob = $false }
    $targetResults = @()
    if ($canJob) {
        $targetJobs = @()
        foreach ($target in $targetList) {
            $targetJobs += Start-Job -ScriptBlock {
                param($t, $curlTimeoutSeconds)

                # Define Get-PingAverage inside job to make it available in child session
                function Get-PingAverage {
                    param([string]$TargetHost)
                    try {
                        if (Get-Command Test-Connection -ErrorAction SilentlyContinue) {
                            $pings = Test-Connection -ComputerName $TargetHost -Count 3 -ErrorAction Stop
                            $avg = ($pings | Measure-Object -Property ResponseTime -Average).Average
                            return "{0:N0} ms" -f $avg
                        } else {
                            $out = & ping.exe -n 3 $TargetHost 2>&1
                            $s = ($out | Out-String)
                            if ($s -match "Average\s*=\s*(\d+)\s*ms") { return "$( $matches[1] ) ms" }
                            if ($s -match "Average\s*=\s*(\d+)\s*мс") { return "$( $matches[1] ) ms" }
                            if ($s -match "Среднее\s*=\s*(\d+)\s*мс") { return "$( $matches[1] ) ms" }
                            return "Timeout"
                        }
                    } catch { return "Timeout" }
                }

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
                    $pingResult = Get-PingAverage -TargetHost $t.PingTarget
                }

                return (New-Object PSObject -Property @{
                    Name       = $t.Name
                    HttpTokens = $httpPieces
                    PingResult = $pingResult
                    IsUrl      = [bool]$t.Url
                })
            } -ArgumentList $target, $curlTimeoutSeconds
        }
        SafeWrite "  > Running tests (parallel)..." DarkGray
        Wait-Job -Job $targetJobs | Out-Null
        $targetResults = foreach ($job in $targetJobs) { Receive-Job -Job $job }
        Remove-Job -Job $targetJobs -Force -ErrorAction SilentlyContinue
    } else {
        SafeWrite "  > Running tests (sequential)..." DarkGray
        foreach ($target in $targetList) {
            # Inline execution for older PowerShell without Start-Job
            $t = $target
            $httpPieces = @()
            if ($t.Url) {
                $tests = @(
                    @{ Label = "HTTP";   Args = @("--http1.1") },
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
                        if ($ok) { $httpPieces += "$($test.Label):OK   " } else { $httpPieces += "$($test.Label):ERROR" }
                    } catch { $httpPieces += "$($test.Label):ERROR" }
                }
            }
            $pingResult = "n/a"
            if ($t.PingTarget) {
                $pingResult = Get-PingAverage -TargetHost $t.PingTarget
            }
            $targetResults += (New-Object PSObject -Property @{ Name = $t.Name; HttpTokens = $httpPieces; PingResult = $pingResult; IsUrl = [bool]$t.Url })
        }
    }

    $script:currentLine = "  > Running tests..."
    SafeWrite $script:currentLine DarkGray

    $targetLookup = @{}
    foreach ($res in $targetResults) { $targetLookup[$res.Name] = $res }

    foreach ($target in $targetList) {
        $res = $targetLookup[$target.Name]
        if (-not $res) { continue }

        SafeWrite "  $($target.Name.PadRight($maxNameLen))    " -NoNewline

        if ($res.IsUrl -and $res.HttpTokens) {
            foreach ($tok in $res.HttpTokens) {
                $tokColor = "Green"
                if ($tok -match "UNSUP") { $tokColor = "Yellow" }
                elseif ($tok -match "ERR") { $tokColor = "Red" }
                SafeWrite " $tok" $tokColor -NoNewline
            }
            SafeWrite " | Ping: " DarkGray -NoNewline
            if ($res.PingResult -eq "Timeout") {
                $pingColor = "Yellow"
            } else {
                $pingColor = "Cyan"
            }
            SafeWrite "$($res.PingResult)" $pingColor -NoNewline
            SafeWrite ""
        } else {
            # Ping-only target
            SafeWrite " Ping: " DarkGray -NoNewline
            if ($res.PingResult -eq "Timeout") {
                $pingColor = "Red"
            } else {
                $pingColor = "Cyan"
            }
            SafeWrite "$($res.PingResult)" $pingColor
        }

    }
    
    # Stop
    Stop-Zapret
    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
}

SafeWrite ""
SafeWrite "All tests finished." Green


