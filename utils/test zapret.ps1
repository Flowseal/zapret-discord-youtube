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
    $raw = [IO.File]::ReadAllText($listFile)
    if ([string]::IsNullOrWhiteSpace($raw)) { return "any" }
    if ($raw -match '203\.0\.113\.113/32') { return "none" }
    return "loaded"
}

function Wait-WinwsReady {
    param(
        [int]$MaxWaitMs = 2500,
        [int]$SettleMs = 400
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $MaxWaitMs) {
        if (Get-Process -Name "winws" -ErrorAction SilentlyContinue) {
            Start-Sleep -Milliseconds $SettleMs
            return
        }
        Start-Sleep -Milliseconds 80
    }
    Start-Sleep -Milliseconds $SettleMs
}

function Complete-Runspaces {
    param(
        [System.Collections.IList]$Runspaces,
        [int]$TimeoutMs
    )

    $results = New-Object System.Collections.Generic.List[object]
    $pending = New-Object System.Collections.Generic.List[object]
    foreach ($rs in $Runspaces) { [void]$pending.Add($rs) }

    while ($pending.Count -gt 0) {
        $now = [Environment]::TickCount
        for ($i = $pending.Count - 1; $i -ge 0; $i--) {
            $rs = $pending[$i]
            $elapsed = ($now - $rs.StartTick) -band [int]::MaxValue
            $timedOut = $elapsed -ge $TimeoutMs
            if (-not $rs.Handle.IsCompleted -and -not $timedOut) { continue }

            if (-not $rs.Handle.IsCompleted -and $timedOut) {
                Write-Host "[WARN] Runspace timed out after $TimeoutMs ms; stopping..." -ForegroundColor Yellow
                try { $rs.Powershell.Stop() } catch {}
            }

            try {
                $res = $rs.Powershell.EndInvoke($rs.Handle)
                if ($null -ne $res) {
                    foreach ($item in @($res)) { [void]$results.Add($item) }
                }
            } catch {
                Write-Host "[WARN] EndInvoke failed for a runspace; treating as failure." -ForegroundColor Yellow
                if ($rs.OnError) { [void]$results.Add((& $rs.OnError)) }
            }
            try { $rs.Powershell.Dispose() } catch {}
            $pending.RemoveAt($i)
        }
        if ($pending.Count -gt 0) { Start-Sleep -Milliseconds 25 }
    }

    return $results
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
$dpiRangeBytes = 65536
$cpuCount = [Math]::Max(1, [int]$env:NUMBER_OF_PROCESSORS)
$dpiMaxParallel = [Math]::Min(16, [Math]::Max(8, $cpuCount * 2))
$dpiCustomHost = $env:MONITOR_HOST
if ($env:MONITOR_TIMEOUT) { [int]$dpiTimeoutSeconds = $env:MONITOR_TIMEOUT }
if ($env:MONITOR_RANGE) { [int]$dpiRangeBytes = $env:MONITOR_RANGE }
if ($env:MONITOR_MAX_PARALLEL) { [int]$dpiMaxParallel = $env:MONITOR_MAX_PARALLEL }
$standardMaxParallel = $dpiMaxParallel
$standardCurlTimeout = 4
if ($env:TEST_CURL_TIMEOUT) { [int]$standardCurlTimeout = $env:TEST_CURL_TIMEOUT }
if ($env:TEST_MAX_PARALLEL) { [int]$standardMaxParallel = $env:TEST_MAX_PARALLEL }

function Get-DpiSuite {
    # Suite sourced from https://github.com/hyperion-cs/dpi-checkers (Apache-2.0 license)
    # Original copyright retained from dpi-checkers repository
    $url = "https://hyperion-cs.github.io/dpi-checkers/ru/tcp-16-20/suite.v2.json"

    try {
        (Invoke-RestMethod -Uri $url -TimeoutSec $dpiTimeoutSeconds) |
            Select-Object `
                @{n='Id';       e={$_.id}},
                @{n='Provider'; e={$_.provider}},
                @{n='Country';  e={$_.country}},
                @{n='Host';     e={$_.host}}
    }
    catch {
        Write-Host "[WARN] Fetch dpi suite failed." -ForegroundColor Yellow
        @()
    }
}

function Build-DpiTargets {
    param(
        [string]$CustomHost
    )

    $suite = Get-DpiSuite
    $targets = @()

    if ($CustomHost) {
        $targets += @{ Id = "CUSTOM"; Provider = "Custom"; Country = "💡"; Host = $CustomHost }
    } else {
        foreach ($entry in $suite) {
            $targets += @{ Id = $entry.Id; Country = $entry.Country; Provider = $entry.Provider; Host = $entry.Host }
        }
    }

    return $targets
}

function Invoke-DpiSuite {
    param(
        [array]$Targets,
        [int]$TimeoutSeconds,
        [int]$RangeBytes,
        [int]$MaxParallel
    )

    $tests = @(
        @{ Label = "HTTP";   Args = @("--http1.1") },
        @{ Label = "TLS1.2"; Args = @("--tlsv1.2", "--tls-max", "1.2") },
        @{ Label = "TLS1.3"; Args = @("--tlsv1.3", "--tls-max", "1.3") }
    )

    $rangeSpec = "0-$($RangeBytes - 1)"
    $warnDetected = $false

    Write-Host "[INFO] Targets: $($Targets.Count) (custom URL overrides suite). Range: $rangeSpec bytes; Timeout: $($TimeoutSeconds)s" -ForegroundColor Cyan
    Write-Host "[INFO] Starting DPI TCP 16-20 checks (parallel: $MaxParallel)..." -ForegroundColor DarkGray

    $runspacePool = [runspacefactory]::CreateRunspacePool(1, $MaxParallel)
    $runspacePool.Open()

    $payload = New-Object byte[] $RangeBytes
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($payload)

    $payloadFile = New-TemporaryFile
    [IO.File]::WriteAllBytes($payloadFile, $payload)

    $scriptBlock = {
        param($payloadFile, $target, $tests, $rangeSpec, $TimeoutSeconds)

        $warned = $false
        $lines = @()

        foreach ($test in $tests) {
            $curlArgs = @(
                "--range", $rangeSpec,
                "-m", $TimeoutSeconds,
                "--connect-timeout", ([Math]::Min(3, $TimeoutSeconds)),
                "-w", "%{http_code} %{size_upload} %{size_download} %{time_total}",
                "-o", "NUL",
                "-X", "POST",
                "--data-binary", "@$payloadFile",
                "-s"
            ) + $test.Args + @("https://$($target.Host)")

            $output = & curl.exe @curlArgs 2>&1
            $exit = $LASTEXITCODE
            $text = if ($output -is [array]) { ($output -join "`n").Trim() } else { "$output".Trim() }

            $code = "NA"
            $upBytes = 0
            $downBytes = 0
            $time = -1

            if ($text -match '^(?<code>\d{3})\s+(?<up>\d+)\s+(?<down>\d+)\s+(?<time>[\d\.]+)$') {
                $code = $matches['code']
                $upBytes = [int64]$matches['up']
                $downBytes = [int64]$matches['down']
                $time = [double]$matches['time']
            } elseif (($exit -eq 35) -or ($text -match "not supported|does not support|protocol\s+'.+'\s+not\s+supported|protocol\s+.+\s+not\s+supported|unsupported protocol|TLS.not supported|Unrecognized option|Unknown option|unsupported option|unsupported feature|schannel|SSL")) {
                $code = "UNSUP"
            } elseif ($text) {
                $code = "ERR"
            }

            $upKB = [math]::Round($upBytes / 1024, 1)
            $downKB = [math]::Round($downBytes / 1024, 1)
            $status = "OK"
            $color = "Green"

            if ($code -eq "UNSUP") {
                $status = "UNSUPPORTED"
                $color = "Yellow"
            } elseif ($exit -ne 0 -or $code -eq "ERR" -or $code -eq "NA") {
                $status = "FAIL"
                $color = "Red"
            }

            if (($upBytes -gt 0) -and ($downBytes -eq 0) -and ($time -ge $TimeoutSeconds) -and ($exit -ne 0)) {
                $status = "LIKELY_BLOCKED"
                $color = "Yellow"
                $warned = $true
            }

            $lines += [PSCustomObject]@{
                TestLabel = $test.Label
                Code      = $code
                UpBytes   = $upBytes
                UpKB      = $upKB
                DownBytes = $downBytes
                DownKB    = $downKB
                Time      = $time
                Status    = $status
                Color     = $color
                Warned    = $warned
            }
        }

        return [PSCustomObject]@{
            TargetId = $target.Id
            Provider = $target.Provider
            Country   = $target.Country
            Lines    = $lines
            Warned   = $warned
        }
    }

    $runspaces = New-Object System.Collections.Generic.List[object]
    $startTick = [Environment]::TickCount
    foreach ($target in $Targets) {
        $powershell = [powershell]::Create().AddScript($scriptBlock)
        [void]$powershell.AddArgument($payloadFile)
        [void]$powershell.AddArgument($target)
        [void]$powershell.AddArgument($tests)
        [void]$powershell.AddArgument($rangeSpec)
        [void]$powershell.AddArgument($TimeoutSeconds)
        $powershell.RunspacePool = $runspacePool

        [void]$runspaces.Add([PSCustomObject]@{
            Powershell = $powershell
            Handle     = $powershell.BeginInvoke()
            TargetId   = $target.Id
            StartTick  = $startTick
            OnError    = {
                $failedLine = [PSCustomObject]@{
                    TestLabel = 'RUNSPACE'; Code = 'ERR'; SizeBytes = 0; SizeKB = 0
                    Status = 'FAIL'; Color = 'Red'; Warned = $false
                }
                [PSCustomObject]@{ TargetId = 'UNKNOWN'; Provider = 'UNKNOWN'; Lines = @($failedLine); Warned = $false }
            }
        })
    }

    # Per-target budget: 3 curl tests + grace
    $waitMs = (([int]$TimeoutSeconds * 3) + 8) * 1000
    $results = @(Complete-Runspaces -Runspaces $runspaces -TimeoutMs $waitMs)

    foreach ($res in $results) {
        if (-not $res) { continue }
        Write-Host "`n=== [$($res.Country)][$($res.Provider)] $($res.TargetId) ===" -ForegroundColor DarkCyan
        foreach ($line in $res.Lines) {
            $msg = "[{0}] code={1} buf_up={2} bytes ({3} KB) buf_down={4} bytes ({5} KB) time={6}s status={7}" -f $line.TestLabel, $line.Code, $line.UpBytes, $line.UpKB, $line.DownBytes, $line.DownKB, $line.Time, $line.Status
            Write-Host $msg -ForegroundColor $line.Color
            if ($line.Status -eq "LIKELY_BLOCKED") {
                Write-Host "  Pattern matches 16-20KB freeze; censor likely cutting this strategy." -ForegroundColor Yellow
            }
        }

        if ($res.Warned) {
            $warnDetected = $true
        } else {
            Write-Host "  No 16-20KB freeze pattern for this target." -ForegroundColor Green
        }
    }
    $runspacePool.Close()
    $runspacePool.Dispose()
    Remove-Item -LiteralPath $payloadFile -Force -ErrorAction SilentlyContinue

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

# Config
$targetDir = $rootDir
if (-not $targetDir) { $targetDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$batFiles = Get-ChildItem -Path $targetDir -Filter "*.bat" | Where-Object { $_.Name -notlike "service*" } | Sort-Object { [Regex]::Replace($_.Name, "(\d+)", { $args[0].Value.PadLeft(8, "0") }) }

$globalResults = @()
$dpiTargets = @()

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

# Load DPI suite only when needed (skips network fetch for standard mode)
if ($testType -eq 'dpi') {
    $dpiTargets = Build-DpiTargets -CustomHost $dpiCustomHost
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
        Add-OrSet $rawTargets "DiscordMain"           "https://discord.com"
        Add-OrSet $rawTargets "DiscordGateway"        "https://gateway.discord.gg"
        Add-OrSet $rawTargets "DiscordCDN"            "https://cdn.discordapp.com"
        Add-OrSet $rawTargets "DiscordUpdates"        "https://updates.discord.com"
        Add-OrSet $rawTargets "YouTubeWeb"            "https://www.youtube.com"
        Add-OrSet $rawTargets "YouTubeShort"          "https://youtu.be"
        Add-OrSet $rawTargets "YouTubeImage"          "https://i.ytimg.com"
        Add-OrSet $rawTargets "YouTubeVideoRedirect" "https://redirector.googlevideo.com"
        Add-OrSet $rawTargets "GoogleMain"            "https://www.google.com"
        Add-OrSet $rawTargets "GoogleGstatic"         "https://www.gstatic.com"
        Add-OrSet $rawTargets "CloudflareWeb"         "https://www.cloudflare.com"
        Add-OrSet $rawTargets "CloudflareCDN"         "https://cdnjs.cloudflare.com"
        Add-OrSet $rawTargets "CloudflareDNS1111"     "PING:1.1.1.1"
        Add-OrSet $rawTargets "CloudflareDNS1001"     "PING:1.0.0.1"
        Add-OrSet $rawTargets "GoogleDNS8888"         "PING:8.8.8.8"
        Add-OrSet $rawTargets "GoogleDNS8844"         "PING:8.8.4.4"
        Add-OrSet $rawTargets "Quad9DNS9999"          "PING:9.9.9.9"
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
$standardPool = $null

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

    if ($testType -eq 'standard') {
        $curlTimeoutSeconds = $standardCurlTimeout
        $maxParallel = $standardMaxParallel

        # Shared scriptblock + pool across all configs (avoids recreate cost)
        $standardScriptBlock = {
            param($t, $curlTimeoutSeconds)

            $httpPieces = New-Object System.Collections.Generic.List[string]

            if ($t.Url) {
                $tests = @(
                    @{ Label = "HTTP";   Args = @("--http1.1") },
                    @{ Label = "TLS1.2"; Args = @("--tlsv1.2", "--tls-max", "1.2") },
                    @{ Label = "TLS1.3"; Args = @("--tlsv1.3", "--tls-max", "1.3") }
                )

                foreach ($test in $tests) {
                    try {
                        $curlArgs = @(
                            "-I", "-s",
                            "-m", $curlTimeoutSeconds,
                            "--connect-timeout", ([Math]::Min(2, $curlTimeoutSeconds)),
                            "-o", "NUL",
                            "-w", "%{http_code}",
                            "--show-error"
                        ) + $test.Args
                        $stderr = $null
                        $output = & curl.exe @curlArgs $t.Url 2>&1 | ForEach-Object {
                            if ($_ -is [System.Management.Automation.ErrorRecord]) {
                                $stderr += $_.Exception.Message + " "
                            } else {
                                $_
                            }
                        }
                        $httpCode = if ($output -is [array]) { ($output -join "").Trim() } else { "$output".Trim() }

                        $dnsHijack = ($stderr -match "Could not resolve host|certificate|SSL certificate problem|self[- ]?signed|certificate verify failed|unable to get local issuer certificate")
                        if ($dnsHijack) {
                            [void]$httpPieces.Add("$($test.Label):SSL  ")
                            continue
                        }

                        $unsupported = (($LASTEXITCODE -eq 35) -or ($stderr -match "does not support|not supported|protocol\s+'?.+'?\s+not\s+supported|unsupported protocol|TLS.*not supported|Unrecognized option|Unknown option|unsupported option|unsupported feature|schannel"))
                        if ($unsupported) {
                            [void]$httpPieces.Add("$($test.Label):UNSUP")
                            continue
                        }

                        if ($LASTEXITCODE -eq 0) {
                            [void]$httpPieces.Add("$($test.Label):OK   ")
                        } else {
                            [void]$httpPieces.Add("$($test.Label):ERROR")
                        }
                    } catch {
                        [void]$httpPieces.Add("$($test.Label):ERROR")
                    }
                }
            }

            $pingResult = "n/a"
            if ($t.PingTarget) {
                try {
                    $pingSender = New-Object System.Net.NetworkInformation.Ping
                    $reply = $pingSender.Send($t.PingTarget, 1000)
                    if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                        $pingResult = "{0:N0} ms" -f $reply.RoundtripTime
                    } else {
                        $pingResult = "Timeout"
                    }
                    $pingSender.Dispose()
                } catch {
                    $pingResult = "Timeout"
                }
            }

            return [PSCustomObject]@{
                Name       = $t.Name
                HttpTokens = @($httpPieces)
                PingResult = $pingResult
                IsUrl      = [bool]$t.Url
            }
        }

        $standardPool = [runspacefactory]::CreateRunspacePool(1, $maxParallel)
        $standardPool.Open()
    }

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
    
    # Wait until winws is up (instead of fixed 5s sleep)
    Wait-WinwsReady -MaxWaitMs 2500 -SettleMs 400
    
    if ($testType -eq 'standard') {
        $runspaces = New-Object System.Collections.Generic.List[object]
        $startTick = [Environment]::TickCount
        foreach ($target in $targetList) {
            $ps = [powershell]::Create().AddScript($standardScriptBlock)
            [void]$ps.AddArgument($target)
            [void]$ps.AddArgument($curlTimeoutSeconds)
            $ps.RunspacePool = $standardPool

            [void]$runspaces.Add([PSCustomObject]@{
                Powershell = $ps
                Handle     = $ps.BeginInvoke()
                StartTick  = $startTick
                OnError    = {
                    [PSCustomObject]@{ Name = 'UNKNOWN'; HttpTokens = @('HTTP:ERROR'); PingResult = 'Timeout'; IsUrl = $true }
                }
            })
        }

        Write-Host "  > Running tests..." -ForegroundColor DarkGray

        # Budget: 3 curl protocols + ping + grace
        $waitMs = (([int]$curlTimeoutSeconds * 3) + 6) * 1000
        $targetResults = @(Complete-Runspaces -Runspaces $runspaces -TimeoutMs $waitMs)

        $targetLookup = @{}
        foreach ($res in $targetResults) {
            if ($res -and $res.Name) { $targetLookup[$res.Name] = $res }
        }

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
        $dpiResults = Invoke-DpiSuite -Targets $dpiTargets -TimeoutSeconds $dpiTimeoutSeconds -RangeBytes $dpiRangeBytes -MaxParallel $dpiMaxParallel
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
    $maxConfigLen = ($analytics.Keys | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum
    foreach ($config in $analytics.Keys) {
        $a = $analytics[$config]
        $configPadded = $config.PadRight($maxConfigLen)
        if ($a.ContainsKey('PingOK')) {
            $line = "{0} : HTTP OK: {1,3}, ERR: {2,3}, UNSUP: {3,3}, Ping OK: {4,3}, Fail: {5,3}" -f `
                $configPadded, $a.OK, $a.ERROR, $a.UNSUP, $a.PingOK, $a.PingFail
        } else {
            $line = "{0} : OK: {1,3}, FAIL: {2,3}, UNSUP: {3,3}, BLOCKED: {4,3}" -f `
                $configPadded, $a.OK, $a.FAIL, $a.UNSUPPORTED, $a.LIKELY_BLOCKED
        }
        Write-Host $line -ForegroundColor Yellow
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

    # Save to file (single write — much faster than many Add-Content calls)
    $dateStr = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $resultFile = Join-Path $resultsDir "test_results_$dateStr.txt"
    $sb = New-Object System.Text.StringBuilder
    foreach ($res in $globalResults) {
        $config = $res.Config
        $type = $res.Type
        $results = $res.Results
        [void]$sb.AppendLine("Config: $config (Type: $type)")
        if ($type -eq 'standard') {
            foreach ($targetRes in $results) {
                $name = $targetRes.Name
                $http = $targetRes.HttpTokens -join ' '
                $ping = $targetRes.PingResult
                [void]$sb.AppendLine("  $name : $http | Ping: $ping")
            }
        } elseif ($type -eq 'dpi') {
            foreach ($targetRes in $results) {
                $id = $targetRes.TargetId
                $provider = $targetRes.Provider
                $country = $targetRes.Country
                if ($country) {
                    [void]$sb.AppendLine("  Target: [$country] $id ($provider)")
                } else {
                    [void]$sb.AppendLine("  Target: $id ($provider)")
                }
                foreach ($line in $targetRes.Lines) {
                    $test = $line.TestLabel
                    $code = $line.Code
                    $up = $line.UpKB
                    $down = $line.DownKB
                    $time = $line.Time
                    $status = $line.Status
                    [void]$sb.AppendLine("    ${test}: code=${code}  up=${up} KB  down=${down} KB  time=${time}s  status=${status}")
                }
            }
        }
        [void]$sb.AppendLine("")
    }

    [void]$sb.AppendLine("=== ANALYTICS ===")
    $maxConfigLen = ($analytics.Keys | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum
    foreach ($config in $analytics.Keys) {
        $a = $analytics[$config]
        $configPadded = $config.PadRight($maxConfigLen)
        if ($a.ContainsKey('PingOK')) {
            $line = "{0} : HTTP OK: {1,3}, ERR: {2,3}, UNSUP: {3,3}, Ping OK: {4,3}, Fail: {5,3}" -f `
                $configPadded, $a.OK, $a.ERROR, $a.UNSUP, $a.PingOK, $a.PingFail
        } else {
            $line = "{0} : OK: {1,3}, FAIL: {2,3}, UNSUP: {3,3}, BLOCKED: {4,3}" -f `
                $configPadded, $a.OK, $a.FAIL, $a.UNSUPPORTED, $a.LIKELY_BLOCKED
        }
        [void]$sb.AppendLine($line)
    }

    [void]$sb.AppendLine("Best strategy: $bestConfig")
    [IO.File]::WriteAllText($resultFile, $sb.ToString(), [Text.UTF8Encoding]::new($false))

    Write-Host "Results saved to $resultFile" -ForegroundColor Green

} catch {
    Write-Host "[ERROR] An error occurred during tests. Restoring ipset..." -ForegroundColor Red
    if ($originalIpsetStatus -and $originalIpsetStatus -ne "any") {
        Set-IpsetMode -mode "restore"
    }
    Remove-Item -Path $ipsetFlagFile -ErrorAction SilentlyContinue
} finally {
    if ($standardPool) {
        try { $standardPool.Close() } catch {}
        try { $standardPool.Dispose() } catch {}
        $standardPool = $null
    }
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
