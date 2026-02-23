$hasErrors = $false

$rootDir = Split-Path $PSScriptRoot
$listsDir = Join-Path $rootDir "lists"
$utilsDir = Join-Path $rootDir "utils"
$resultsDir = Join-Path $utilsDir "test results"
if (-not (Test-Path $resultsDir)) { New-Item -ItemType Directory -Path $resultsDir | Out-Null }

# Define functions early
function Get-IpsetStatus {
    $listFile = Join-Path $listsDir "ipset-all.txt"
    if (-not (Test-Path $listFile)) { return "none" }
    $lineCount = (Get-Content $listFile | Measure-Object -Line).Lines
    if ($lineCount -eq 0) { return "any" }
    $hasDummy = Get-Content $listFile | Select-String -Pattern "203\.0\.113\.113/32" -Quiet
    if ($hasDummy) { return "none" } else { return "loaded" }
}

function Set-IpsetMode {
    param([string]$mode)
    $listFile = Join-Path $listsDir "ipset-all.txt"
    $backupFile = Join-Path $listsDir "ipset-all.test-backup.txt"
    if ($mode -eq "any") {
        # Always backup current file (even if none)
        if (Test-Path $listFile) {
            Copy-Item $listFile $backupFile -Force
        } else {
            # If none, create empty backup
            "" | Out-File $backupFile -Encoding UTF8
        }
        # Make file empty
        "" | Out-File $listFile -Encoding UTF8
    } elseif ($mode -eq "restore") {
        if (Test-Path $backupFile) {
            Move-Item $backupFile $listFile -Force
        }
    }
}

trap {
    Write-Host "[ERROR] Script interrupted. Restoring ipset..." -ForegroundColor Red
    if ($originalIpsetStatus -and $originalIpsetStatus -ne "any") {
        Set-IpsetMode -mode "restore"
    }
    Remove-Item -Path $ipsetFlagFile -ErrorAction SilentlyContinue
    break
}

function New-OrderedDict { New-Object System.Collections.Specialized.OrderedDictionary }
function Add-OrSet {
    param($dict, $key, $val)
    if ($dict.Contains($key)) { $dict[$key] = $val } else { $dict.Add($key, $val) }
}

# Convert raw target value to structured target (supports PING:ip for ping-only targets)
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

# DPI checker defaults (override via MONITOR_* env vars like in monitor.ps1)
$dpiTimeoutSeconds = 5
$dpiRangeBytes = 262144
$dpiWarnMinKB = 14
$dpiWarnMaxKB = 22
$dpiMaxParallel = 8
$dpiCustomUrl = $env:MONITOR_URL
if ($env:MONITOR_TIMEOUT) { [int]$dpiTimeoutSeconds = $env:MONITOR_TIMEOUT }
if ($env:MONITOR_RANGE) { [int]$dpiRangeBytes = $env:MONITOR_RANGE }
if ($env:MONITOR_WARN_MINKB) { [int]$dpiWarnMinKB = $env:MONITOR_WARN_MINKB }
if ($env:MONITOR_WARN_MAXKB) { [int]$dpiWarnMaxKB = $env:MONITOR_WARN_MAXKB }
if ($env:MONITOR_MAX_PARALLEL) { [int]$dpiMaxParallel = $env:MONITOR_MAX_PARALLEL }

function Get-DpiSuite {
    # Suite sourced from https://github.com/hyperion-cs/dpi-checkers (Apache-2.0 license)
    # Original copyright retained from dpi-checkers repository
    $url = "https://hyperion-cs.github.io/dpi-checkers/ru/tcp-16-20/suite.json"

    try {
        (Invoke-RestMethod -Uri $url -TimeoutSec $dpiTimeoutSeconds) |
            Select-Object `
                @{n='Id';       e={$_.id}},
                @{n='Provider'; e={$_.provider}},
                @{n='Url';      e={$_.url}},
                @{n='Times';    e={$_.times}}
    }
    catch {
        Write-Host "[WARN] Fetch dpi suite failed." -ForegroundColor Yellow
        @()
    }
}

function Build-DpiTargets {
    param(
        [string]$CustomUrl
    )

    $suite = Get-DpiSuite
    $targets = @()

    if ($CustomUrl) {
        $targets += @{ Id = "CUSTOM"; Provider = "Custom"; Url = $CustomUrl }
    } else {
        foreach ($entry in $suite) {
            $repeat = $entry.Times
            if (-not $repeat -or $repeat -lt 1) { $repeat = 1 }
            for ($i = 0; $i -lt $repeat; $i++) {
                $suffix = ""
                if ($repeat -gt 1) { $suffix = "@$i" }
                $targets += @{ Id = "$($entry.Id)$suffix"; Provider = $entry.Provider; Url = $entry.Url }
            }
        }
    }

    return $targets
}

function Invoke-DpiSuite {
    param(
        [array]$Targets,
        [int]$TimeoutSeconds,
        [int]$RangeBytes,
        [int]$WarnMinKB,
        [int]$WarnMaxKB,
        [int]$MaxParallel
    )

    $tests = @(
        @{ Label = "HTTP";   Args = @("--http1.1") },
        @{ Label = "TLS1.2"; Args = @("--tlsv1.2", "--tls-max", "1.2") },
        @{ Label = "TLS1.3"; Args = @("--tlsv1.3", "--tls-max", "1.3") }
    )

    $rangeSpec = "0-$($RangeBytes - 1)"
    $warnDetected = $false

    Write-Host "[INFO] Targets: $($Targets.Count) (custom URL overrides suite). Range: $rangeSpec bytes; Timeout: $TimeoutSeconds s; Warn window: $WarnMinKB-$WarnMaxKB KB" -ForegroundColor Cyan
    Write-Host "[INFO] Starting DPI TCP 16-20 checks (parallel: $MaxParallel)..." -ForegroundColor DarkGray

    $runspacePool = [runspacefactory]::CreateRunspacePool(1, $MaxParallel)
    $runspacePool.Open()

    $scriptBlock = {
        param($target, $tests, $rangeSpec, $TimeoutSeconds, $WarnMinKB, $WarnMaxKB)

        $warned = $false
        $lines = @()

        foreach ($test in $tests) {
            $curlArgs = @(
                "-L",
                "--range", $rangeSpec,
                "-m", $TimeoutSeconds,
                "-w", "%{http_code} %{size_download}",
                "-o", "NUL",
                "-s"
            ) + $test.Args + $target.Url

            $output = & curl.exe @curlArgs 2>&1
            $exit = $LASTEXITCODE
            $text = ($output | Out-String).Trim()

            $code = "NA"
            $sizeBytes = 0

            if ($text -match '^(?<code>\d{3})\s+(?<size>\d+)$') {
                $code = $matches['code']
                $sizeBytes = [int64]$matches['size']
            } elseif (($exit -eq 35) -or ($text -match "not supported|does not support|protocol\s+'.+'\s+not\s+supported|protocol\s+.+\s+not\s+supported|unsupported protocol|TLS.not supported|Unrecognized option|Unknown option|unsupported option|unsupported feature|schannel|SSL")) {
                $code = "UNSUP"
            } elseif ($text) {
                $code = "ERR"
            }

            $sizeKB = [math]::Round($sizeBytes / 1024, 1)
            $status = "OK"
            $color = "Green"

            if ($code -eq "UNSUP") {
                $status = "UNSUPPORTED"
                $color = "Yellow"
            } elseif ($exit -ne 0 -or $code -eq "ERR" -or $code -eq "NA") {
                $status = "FAIL"
                $color = "Red"
            }

            if (($sizeKB -ge $WarnMinKB) -and ($sizeKB -le $WarnMaxKB) -and ($exit -ne 0)) {
                $status = "LIKELY_BLOCKED"
                $color = "Yellow"
                $warned = $true
            }

            $lines += [PSCustomObject]@{
                TargetId   = $target.Id
                Provider   = $target.Provider
                TestLabel  = $test.Label
                Code       = $code
                SizeBytes  = $sizeBytes
                SizeKB     = $sizeKB
                Status     = $status
                Color      = $color
                Warned     = $warned
            }
        }

        return [PSCustomObject]@{
            TargetId = $target.Id
            Provider = $target.Provider
            Lines    = $lines
            Warned   = $warned
        }
    }

    $runspaces = @()
    foreach ($target in $Targets) {
        $powershell = [powershell]::Create().AddScript($scriptBlock)
        [void]$powershell.AddArgument($target)
        [void]$powershell.AddArgument($tests)
        [void]$powershell.AddArgument($rangeSpec)
        [void]$powershell.AddArgument($TimeoutSeconds)
        [void]$powershell.AddArgument($WarnMinKB)
        [void]$powershell.AddArgument($WarnMaxKB)
        $powershell.RunspacePool = $runspacePool

        $runspaces += [PSCustomObject]@{
            Powershell = $powershell
            Handle     = $powershell.BeginInvoke()
        }
    }

    $results = @()
    foreach ($rs in $runspaces) {
        # Wait for the runspace to complete with a small grace period beyond curl's timeout
        try {
            $waitMs = ([int]$TimeoutSeconds + 5) * 1000
            $handle = $rs.Handle
            if ($handle -and $handle.AsyncWaitHandle) {
                $completed = $handle.AsyncWaitHandle.WaitOne($waitMs)
                if (-not $completed) {
                    Write-Host "[WARN] Runspace for target timed out after $waitMs ms; stopping runspace..." -ForegroundColor Yellow
                    try { $rs.Powershell.Stop() } catch {}
                }
            }
        } catch {
            # ignore wait errors and attempt to EndInvoke
        }

        try {
            $results += $rs.Powershell.EndInvoke($rs.Handle)
        } catch {
            Write-Host "[WARN] EndInvoke failed for a runspace; treating as failure." -ForegroundColor Yellow
            $failedLine = [PSCustomObject]@{
                TestLabel  = 'RUNSPACE'
                Code       = 'ERR'
                SizeBytes  = 0
                SizeKB     = 0
                Status     = 'FAIL'
                Color      = 'Red'
                Warned     = $false
            }
            $results += [PSCustomObject]@{ TargetId = 'UNKNOWN'; Provider = 'UNKNOWN'; Lines = @($failedLine); Warned = $false }
        }
        $rs.Powershell.Dispose()
    }
    $runspacePool.Close()
    $runspacePool.Dispose()

    foreach ($res in $results) {
        Write-Host "`n=== $($res.TargetId) [$($res.Provider)] ===" -ForegroundColor DarkCyan

        foreach ($line in $res.Lines) {
            $msg = "[{0}][{1}] code={2} size={3} bytes ({4} KB) status={5}" -f $line.TargetId, $line.TestLabel, $line.Code, $line.SizeBytes, $line.SizeKB, $line.Status
            Write-Host $msg -ForegroundColor $line.Color
            if ($line.Status -eq "LIKELY_BLOCKED") {
                Write-Host "  Pattern matches 16-20KB freeze; censor likely cutting this strategy." -ForegroundColor Yellow
            }
        }

        if (-not $res.Warned) {
            Write-Host "  No 16-20KB freeze pattern for this target." -ForegroundColor Green
        } else {
            $warnDetected = $true
        }
    }

    if ($warnDetected) {
        Write-Host ""
        Write-Host "[WARNING] Detected possible DPI TCP 16-20 blocking on one or more targets. Consider changing strategy/SNI/IP." -ForegroundColor Red
    } else {
        Write-Host ""
        Write-Host "[OK] No 16-20KB freeze pattern detected across targets." -ForegroundColor Green
    }

    return $results
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

# Check for leftover ipset flag from previous interrupted run
$ipsetFlagFile = Join-Path $rootDir "ipset_switched.flag"
if (Test-Path $ipsetFlagFile) {
    Write-Host "[INFO] Detected leftover ipset switch flag. Restoring ipset..." -ForegroundColor Yellow
    Set-IpsetMode -mode "restore"
    Remove-Item -Path $ipsetFlagFile -ErrorAction SilentlyContinue
}

# Get original ipset status early
$originalIpsetStatus = Get-IpsetStatus

# Warn about ipset switching and X button behavior
if ($originalIpsetStatus -ne "any") {
    Write-Host "[INFO] Current ipset status: $originalIpsetStatus" -ForegroundColor Cyan
    Write-Host "[WARNING] Ipset will be switched to 'any' for accurate DPI tests." -ForegroundColor Yellow
    Write-Host "[WARNING] If you close the window with the X button, ipset will NOT restore immediately." -ForegroundColor Yellow
    Write-Host "[WARNING] It will be restored automatically on the next script run." -ForegroundColor Yellow
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
    Write-Host "Press any key to exit..." -ForegroundColor Yellow
    [void][System.Console]::ReadKey($true)
    exit 1
}

$dpiTargets = Build-DpiTargets -CustomUrl $dpiCustomUrl

# Config
$targetDir = $rootDir
if (-not $targetDir) { $targetDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$batFiles = Get-ChildItem -Path $targetDir -Filter "*.bat" | Where-Object { $_.Name -notlike "service*" } | Sort-Object { [Regex]::Replace($_.Name, "(\d+)", { $args[0].Value.PadLeft(8, "0") }) }

$globalResults = @()

# Select top-level test type (standard vs DPI checkers)
function Read-TestType {
    while ($true) {
        Write-Host ""
        Write-Host "Select test type:" -ForegroundColor Cyan
        Write-Host "  [1] Standard tests (HTTP/ping)" -ForegroundColor Gray
        Write-Host "  [2] DPI checkers (TCP 16-20 freeze)" -ForegroundColor Gray
        $choice = Read-Host "Enter 1 or 2"
        switch ($choice) {
            '1' { return 'standard' }
            '2' { return 'dpi' }
            default { Write-Host "Incorrect input. Please try again." -ForegroundColor Yellow }
        }
    }
}

# Select test mode: all configs or custom subset
function Read-ModeSelection {
    while ($true) {
        Write-Host ""
        Write-Host "Select test run mode:" -ForegroundColor Cyan
        Write-Host "  [1] All configs" -ForegroundColor Gray
        Write-Host "  [2] Selected configs" -ForegroundColor Gray
        $choice = Read-Host "Enter 1 or 2"
        switch ($choice) {
            '1' { return 'all' }
            '2' { return 'select' }
            default { Write-Host "Incorrect input. Please try again." -ForegroundColor Yellow }
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

        $selectionInput = Read-Host "Enter numbers (e.g. 1,3,5) , ranges (e.g. 2-7), or mixed (e.g. 1,5-10,12). '0' for all"
        $trimmed = $selectionInput.Trim()
        
        if ($trimmed -eq '0') {
            return $allFiles
        }

        $parts = $selectionInput -split '[,\s]+' | Where-Object { $_ -match '^\d+(-\d+)?$' }
        if ($parts.Count -eq 0) {
            Write-Host ""
            Write-Host "Invalid input format. Use numbers, ranges (1-5), or combinations (1,3-7,10). Try again." -ForegroundColor Yellow
            continue
        }
        $selectedIndices = @()
        $hasErrors = $false
        
        foreach ($part in $parts) {
            if ($part -match '^(\d+)-(\d+)$') {
                $start = [int]$matches[1]
                $end = [int]$matches[2]
                
                if ($start -gt $end) {
                    Write-Host "  [WARN] Invalid range '$part' (start > end). Skipping." -ForegroundColor Yellow
                    $hasErrors = $true
                    continue
                }
                
                if ($start -lt 1 -or $end -gt $allFiles.Count) {
                    Write-Host "  [WARN] Range '$part' out of bounds (valid: 1-$($allFiles.Count)). Skipping invalid parts." -ForegroundColor Yellow
                    $hasErrors = $true
                    $start = [Math]::Max($start, 1)
                    $end = [Math]::Min($end, $allFiles.Count)
                }
                
                for ($i = $start; $i -le $end; $i++) {
                    $selectedIndices += $i
                }
            } else {
                $num = [int]$part
                if ($num -ge 1 -and $num -le $allFiles.Count) {
                    $selectedIndices += $num
                } else {
                    Write-Host "  [WARN] Number '$num' out of bounds (valid: 1-$($allFiles.Count)). Skipping." -ForegroundColor Yellow
                    $hasErrors = $true
                }
            }
        }
        $valid = $selectedIndices | Sort-Object -Unique | Where-Object { $_ -ge 1 -and $_ -le $allFiles.Count }
        if ($valid.Count -eq 0) {
            Write-Host ""
            Write-Host "No valid configs selected. Try again." -ForegroundColor Yellow
            continue
        }

        # Checker
         Write-Host "Selected configs: $($valid -join ', ')" -ForegroundColor Green
        if ($hasErrors) {
            Write-Host "Some entries were skipped due to errors (see warnings above)." -ForegroundColor Yellow
        }
        
        return $valid | ForEach-Object { $allFiles[$_ - 1] }
    }
}

while ($true) {
    $globalResults = @()
$testType = Read-TestType
$mode = Read-ModeSelection
if ($mode -eq 'select') {
    $selected = Read-ConfigSelection -allFiles $batFiles
    $batFiles = @($selected)
}

# Load targets once for standard mode
$targetList = @()
$maxNameLen = 10
if ($testType -eq 'standard') {
    $targetsFile = Join-Path $utilsDir "targets.txt"
    $rawTargets = New-OrderedDict
    if (Test-Path $targetsFile) {
        Get-Content $targetsFile | ForEach-Object {
            if ($_ -match '^\s*(\w+)\s*=\s*"(.+)"\s*$') {
                Add-OrSet -dict $rawTargets -key $matches[1] -val $matches[2]
            }
        }
    }

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
        Write-Host ""
        Write-Host "[INFO] Loaded targets from targets.txt" -ForegroundColor Gray
        Write-Host "[INFO] Targets loaded: $($rawTargets.Count)" -ForegroundColor Gray
    }

    foreach ($key in $rawTargets.Keys) {
        $targetList += Convert-Target -Name $key -Value $rawTargets[$key]
    }

    $maxNameLen = ($targetList | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum
    if (-not $maxNameLen -or $maxNameLen -lt 10) { $maxNameLen = 10 }
}

# Ensure we have configs to run
if (-not $batFiles -or $batFiles.Count -eq 0) {
    Write-Host "[ERROR] No general*.bat files found" -ForegroundColor Red
    Write-Host "Press any key to exit..." -ForegroundColor Yellow
    [void][System.Console]::ReadKey($true)
    exit 1
}

# Stop winws
function Stop-Zapret {
    Get-Process -Name "winws" -ErrorAction SilentlyContinue | Stop-Process -Force
}

# Capture/restore running winws instances to return user ipset/config
function Get-WinwsSnapshot {
    try {
        return Get-CimInstance Win32_Process -Filter "Name='winws.exe'" |
            Select-Object ProcessId, CommandLine, ExecutablePath
    } catch {
        return @()
    }
}

function Restore-WinwsSnapshot {
    param($snapshot)

    if (-not $snapshot -or $snapshot.Count -eq 0) { return }

    $current = @()
    try { $current = (Get-WinwsSnapshot).CommandLine } catch { $current = @() }

    Write-Host "[INFO] Restoring previously running winws instances..." -ForegroundColor DarkGray
    foreach ($p in $snapshot) {
        if (-not $p.ExecutablePath) { continue }

        # Skip if an identical command line is already active
        if ($current -and $current -contains $p.CommandLine) { continue }

        $exe = $p.ExecutablePath
        $processArgs = ""
        if ($p.CommandLine) {
            $quotedExe = '"' + $exe + '"'
            if ($p.CommandLine.StartsWith($quotedExe)) {
                $processArgs = $p.CommandLine.Substring($quotedExe.Length).Trim()
            } elseif ($p.CommandLine.StartsWith($exe)) {
                $processArgs = $p.CommandLine.Substring($exe.Length).Trim()
            }
        }

        Start-Process -FilePath $exe -ArgumentList $processArgs -WorkingDirectory (Split-Path $exe -Parent) -WindowStyle Minimized | Out-Null
    }
}

$env:NO_UPDATE_CHECK = "1"
$originalWinws = Get-WinwsSnapshot

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "                 ZAPRET CONFIG TESTS" -ForegroundColor Cyan
Write-Host "                 Mode: $($testType.ToUpper())" -ForegroundColor Cyan
Write-Host "                 Total configs: $($batFiles.Count.ToString().PadLeft(2))" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

try {
    # Save original ipset status and switch to 'any' for accurate DPI tests
    if (($originalIpsetStatus -ne "any") -and ($testType -eq 'dpi')) {
        Write-Host "[WARNING] Ipset is in '$originalIpsetStatus' mode. Switching to 'any' for accurate DPI tests..." -ForegroundColor Yellow
        Set-IpsetMode -mode "any"
        # Create flag file to indicate ipset was switched
        "" | Out-File -FilePath $ipsetFlagFile -Encoding UTF8
    }
    Write-Host "[WARNING] Tests may take several minutes to complete. Please wait..." -ForegroundColor Yellow

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
    
    if ($testType -eq 'standard') {
        $curlTimeoutSeconds = 5

        # Parallel target checks via runspace pool (faster than jobs)
        $maxParallel = 8
        $runspacePool = [runspacefactory]::CreateRunspacePool(1, $maxParallel)
        $runspacePool.Open()

        $scriptBlock = {
            param($t, $curlTimeoutSeconds)

            $httpPieces = @()

            if ($t.Url) {
                $tests = @(
                    @{ Label = "HTTP";   Args = @("--http1.1") },
                    @{ Label = "TLS1.2"; Args = @("--tlsv1.2", "--tls-max", "1.2") },
                    @{ Label = "TLS1.3"; Args = @("--tlsv1.3", "--tls-max", "1.3") }
                )

                $baseArgs = @("-I", "-s", "-m", $curlTimeoutSeconds, "-o", "NUL", "-w", "%{http_code}", "--show-error")
                foreach ($test in $tests) {
                    try {
                        $curlArgs = $baseArgs + $test.Args
                        $stderr = $null
                        $output = & curl.exe @curlArgs $t.Url 2>&1 | ForEach-Object {
                            if ($_ -is [System.Management.Automation.ErrorRecord]) {
                                $stderr += $_.Exception.Message + " "
                            } else {
                                $_
                            }
                        }
                        $httpCode = ($output | Out-String).Trim()
                        
                        $dnsHijack = ($stderr -match "Could not resolve host|certificate|SSL certificate problem|self[- ]?signed|certificate verify failed|unable to get local issuer certificate")                        
                        if ($dnsHijack) {
                            $httpPieces += "$($test.Label):SSL  "
                            continue
                        }
                        
                        $unsupported = (($LASTEXITCODE -eq 35) -or ($stderr -match "does not support|not supported|protocol\s+'?.+'?\s+not\s+supported|unsupported protocol|TLS.*not supported|Unrecognized option|Unknown option|unsupported option|unsupported feature|schannel"))
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
        }

        $runspaces = @()
        foreach ($target in $targetList) {
            $ps = [powershell]::Create().AddScript($scriptBlock)
            [void]$ps.AddArgument($target)
            [void]$ps.AddArgument($curlTimeoutSeconds)
            $ps.RunspacePool = $runspacePool

            $runspaces += [PSCustomObject]@{
                Powershell = $ps
                Handle     = $ps.BeginInvoke()
            }
        }

        $script:currentLine = "  > Running tests..."
        Write-Host $script:currentLine -ForegroundColor DarkGray

        $targetResults = @()
        foreach ($rs in $runspaces) {
            try {
                $waitMs = ([int]$curlTimeoutSeconds + 5) * 1000
                $handle = $rs.Handle
                if ($handle -and $handle.AsyncWaitHandle) {
                    $completed = $handle.AsyncWaitHandle.WaitOne($waitMs)
                    if (-not $completed) {
                        Write-Host "[WARN] Runspace for target timed out after $waitMs ms; stopping runspace..." -ForegroundColor Yellow
                        try { $rs.Powershell.Stop() } catch {}
                    }
                }
            } catch {
                # ignore
            }

            try {
                $targetResults += $rs.Powershell.EndInvoke($rs.Handle)
            } catch {
                Write-Host "[WARN] EndInvoke failed for a runspace; treating as failure." -ForegroundColor Yellow
                $targetResults += [PSCustomObject]@{ Name = 'UNKNOWN'; HttpTokens = @('HTTP:ERROR'); PingResult = 'Timeout'; IsUrl = $true }
            }
            $rs.Powershell.Dispose()
        }

        $runspacePool.Close()
        $runspacePool.Dispose()

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
                    elseif ($tok -match "SSL") { $tokColor = "Red" }
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

        $globalResults += @{ Config = $file.Name; Type = 'standard'; Results = $targetResults }
    } else {
        Write-Host "  > Running DPI checkers..." -ForegroundColor DarkGray
        $dpiResults = Invoke-DpiSuite -Targets $dpiTargets -TimeoutSeconds $dpiTimeoutSeconds -RangeBytes $dpiRangeBytes -WarnMinKB $dpiWarnMinKB -WarnMaxKB $dpiWarnMaxKB -MaxParallel $dpiMaxParallel
        $globalResults += @{ Config = $file.Name; Type = 'dpi'; Results = $dpiResults }
    }
    
    # Stop
    Stop-Zapret
    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
}

    Write-Host ""
    Write-Host "All tests finished." -ForegroundColor Green

    # Analytics
    $analytics = @{}
    foreach ($res in $globalResults) {
        if ($res.Type -eq 'standard') {
            foreach ($targetRes in $res.Results) {
                $config = $res.Config
                if (-not $analytics.ContainsKey($config)) { $analytics[$config] = @{ OK = 0; ERROR = 0; UNSUP = 0; PingOK = 0; PingFail = 0 } }
                if ($targetRes.IsUrl) {
                    foreach ($tok in $targetRes.HttpTokens) {
                        if ($tok -match "OK") { $analytics[$config].OK++ }
                        elseif ($tok -match "SSL") { $analytics[$config].ERROR++ }
                        elseif ($tok -match "ERROR") { $analytics[$config].ERROR++ }
                        elseif ($tok -match "UNSUP") { $analytics[$config].UNSUP++ }
                    }
                }
                if ($targetRes.PingResult -ne "Timeout" -and $targetRes.PingResult -ne "n/a") { $analytics[$config].PingOK++ } else { $analytics[$config].PingFail++ }
            }
        } elseif ($res.Type -eq 'dpi') {
            foreach ($targetRes in $res.Results) {
                $config = $res.Config
                if (-not $analytics.ContainsKey($config)) { $analytics[$config] = @{ OK = 0; FAIL = 0; UNSUPPORTED = 0; LIKELY_BLOCKED = 0 } }
                foreach ($line in $targetRes.Lines) {
                    if ($line.Status -eq "OK") { $analytics[$config].OK++ }
                    elseif ($line.Status -eq "FAIL") { $analytics[$config].FAIL++ }
                    elseif ($line.Status -eq "UNSUPPORTED") { $analytics[$config].UNSUPPORTED++ }
                    elseif ($line.Status -eq "LIKELY_BLOCKED") { $analytics[$config].LIKELY_BLOCKED++ }
                }
            }
        }
    }

    Write-Host ""
    Write-Host "=== ANALYTICS ===" -ForegroundColor Cyan
    foreach ($config in $analytics.Keys) {
        $a = $analytics[$config]
        if ($a.ContainsKey('PingOK')) {
            Write-Host "$config : HTTP OK: $($a.OK), ERR: $($a.ERROR), UNSUP: $($a.UNSUP), Ping OK: $($a.PingOK), Fail: $($a.PingFail)" -ForegroundColor Yellow
        } else {
            Write-Host "$config : OK: $($a.OK), FAIL: $($a.FAIL), UNSUP: $($a.UNSUPPORTED), BLOCKED: $($a.LIKELY_BLOCKED)" -ForegroundColor Yellow
        }
    }

    # Determine best strategy
    $bestConfig = $null
    $maxScore = 0
    $maxPing = -1
    foreach ($config in $analytics.Keys) {
        $a = $analytics[$config]
        $score = $a.OK
        $pingScore = 0
        if ($a.ContainsKey('PingOK')) {
            $pingScore = $a.PingOK
        }
        if ($score -gt $maxScore) {
            $maxScore = $score
            $maxPing = $pingScore
            $bestConfig = $config
        } elseif ($score -eq $maxScore) {
            if ($pingScore -gt $maxPing) {
                $maxPing = $pingScore
                $bestConfig = $config
            }
        }
    }
    Write-Host ""
    Write-Host "Best config: $bestConfig" -ForegroundColor Green
    Write-Host ""

    # Save to file
    $dateStr = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $resultFile = Join-Path $resultsDir "test_results_$dateStr.txt"
    # Clear file
    "" | Out-File $resultFile -Encoding UTF8
    foreach ($res in $globalResults) {
        $config = $res.Config
        $type = $res.Type
        $results = $res.Results
        Add-Content $resultFile "Config: $config (Type: $type)"
        if ($type -eq 'standard') {
            foreach ($targetRes in $results) {
                $name = $targetRes.Name
                $http = $targetRes.HttpTokens -join ' '
                $ping = $targetRes.PingResult
                Add-Content $resultFile "  $name : $http | Ping: $ping"
            }
        } elseif ($type -eq 'dpi') {
            foreach ($targetRes in $results) {
                $id = $targetRes.TargetId
                $provider = $targetRes.Provider
                Add-Content $resultFile "  Target: $id ($provider)"
                foreach ($line in $targetRes.Lines) {
                    $test = $line.TestLabel
                    $code = $line.Code
                    $size = $line.SizeKB
                    $status = $line.Status
                    Add-Content $resultFile "    ${test}: code=${code} size=${size} KB status=${status}"
                }
            }
        }
        Add-Content $resultFile ""
    }

    # Add analytics
    Add-Content $resultFile "=== ANALYTICS ==="
    foreach ($config in $analytics.Keys) {
        $a = $analytics[$config]
        if ($a.ContainsKey('PingOK')) {
            Add-Content $resultFile "$config : HTTP OK: $($a.OK), ERR: $($a.ERROR), UNSUP: $($a.UNSUP), Ping OK: $($a.PingOK), Fail: $($a.PingFail)"
        } else {
            Add-Content $resultFile "$config : OK: $($a.OK), FAIL: $($a.FAIL), UNSUP: $($a.UNSUPPORTED), BLOCKED: $($a.LIKELY_BLOCKED)"
        }
    }

    Add-Content $resultFile "Best strategy: $bestConfig"

    Write-Host "Results saved to $resultFile" -ForegroundColor Green

} catch {
    Write-Host "[ERROR] An error occurred during tests. Restoring ipset..." -ForegroundColor Red
    if ($originalIpsetStatus -and $originalIpsetStatus -ne "any") {
        Set-IpsetMode -mode "restore"
    }
    Remove-Item -Path $ipsetFlagFile -ErrorAction SilentlyContinue
} finally {
    Stop-Zapret
    Restore-WinwsSnapshot -snapshot $originalWinws
    if ($originalIpsetStatus -ne "any") {
        Write-Host "[INFO] Restoring original ipset mode..." -ForegroundColor DarkGray
        Set-IpsetMode -mode "restore"
    }
    Remove-Item -Path $ipsetFlagFile -ErrorAction SilentlyContinue
}

    Write-Host "Press any key to close..." -ForegroundColor Yellow
    [void][System.Console]::ReadKey($true)
    exit
}
