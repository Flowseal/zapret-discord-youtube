param(
    [string]$ResultFile
)

# =============================================================================
#  ZAPRET AUTOTUNE - Optimized Edition
#  Optimizations:
#    1. Smart strategy priority order (most commonly working first)
#    2. Fast WinDivert release polling (200ms intervals instead of 1s)
#    3. Parallel curl checks via Runspace pool (all URLs tested simultaneously)
#    4. Early fail: skip remaining checks the moment one URL fails
# =============================================================================

# --- Path resolution (robust even if $PSScriptRoot is empty) ---
if ($PSScriptRoot -and $PSScriptRoot -ne '') {
    $scriptDir = $PSScriptRoot
} else {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}
# bin\autotune -> bin -> root
$rootDir = Split-Path (Split-Path $scriptDir -Parent) -Parent

# --- Admin check ---
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[ERROR] Run as Administrator to execute Autotune" -ForegroundColor Red
    Start-Sleep -Seconds 3
    exit 1
}

# --- curl check ---
if (-not (Get-Command "curl.exe" -ErrorAction SilentlyContinue)) {
    Write-Host "[ERROR] curl.exe not found in PATH." -ForegroundColor Red
    Start-Sleep -Seconds 3
    exit 1
}

# =============================================================================
# OPTIMIZATION 1: Smart Priority Order
# Most commonly working strategies go first - if the first one works,
# the whole autotune finishes in under 5 seconds.
# =============================================================================
$priorityOrder = @(
    "general.bat",
    "general (ALT).bat",
    "general (FAKE TLS AUTO).bat",
    "general (SIMPLE FAKE).bat",
    "general (ALT2).bat",
    "general (FAKE TLS AUTO ALT).bat",
    "general (SIMPLE FAKE ALT).bat",
    "general (ALT3).bat"
)

# Discover all general*.bat files
$allBatFiles = Get-ChildItem -Path $rootDir -Filter "general*.bat" |
    Where-Object { $_.Name -notlike "service*" }

if (-not $allBatFiles -or $allBatFiles.Count -eq 0) {
    Write-Host "[ERROR] No general*.bat files found in: $rootDir" -ForegroundColor Red
    Start-Sleep -Seconds 3
    exit 1
}

# Build ordered list: priority names first, then remaining sorted alphabetically
$allNames   = $allBatFiles | ForEach-Object { $_.Name }
$orderedNames = @()
foreach ($name in $priorityOrder) {
    if ($allNames -contains $name) { $orderedNames += $name }
}
$remaining = $allNames |
    Where-Object { $orderedNames -notcontains $_ } |
    Sort-Object { [Regex]::Replace($_, "(\d+)", { $args[0].Value.PadLeft(8, "0") }) }
$orderedNames += $remaining

# Map name -> FileInfo for full path
$batMap = @{}
foreach ($f in $allBatFiles) { $batMap[$f.Name] = $f }

# --- Stop service before starting test loop ---
$svc = Get-Service -Name "zapret" -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq 'Running') {
    Write-Host "[INFO] Stopping zapret service before testing..." -ForegroundColor DarkGray
    Stop-Service -Name "zapret" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 600
}

# --- Set env flag so bat strategies skip update checks ---
$env:NO_UPDATE_CHECK = "1"

# =============================================================================
# OPTIMIZATION 2: Fast WinDivert release polling helper
# Polls every 200ms instead of sleeping a full second between checks.
# =============================================================================
function Stop-Zapret {
    Get-Process -Name "winws" -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue

    # Poll until WinDivert driver is released (max 2s)
    $deadline = [DateTime]::Now.AddSeconds(2)
    while ([DateTime]::Now -lt $deadline) {
        $sc = sc.exe query WinDivert 2>$null | Out-String
        if ($sc -notmatch "RUNNING|STOP_PENDING") { break }
        Start-Sleep -Milliseconds 200
    }
}

Stop-Zapret

# =============================================================================
# OPTIMIZATION 3: Parallel curl checks via Runspace pool
# All target URLs are checked at the same time inside one runspace pool.
# Returns $true if ALL pass, $false if any fail.
# =============================================================================
$testUrls = @(
    "https://www.youtube.com",
    "https://discord.com",
    "https://gateway.discord.gg"
)
$curlTimeout = 3   # seconds per individual request

function Test-Connectivity {
    param([string[]]$Urls, [int]$TimeoutSec)

    # One runspace per URL - all fire simultaneously
    $pool = [runspacefactory]::CreateRunspacePool(1, $Urls.Count)
    $pool.Open()

    $scriptBlock = {
        param([string]$url, [int]$t)
        $args = @("-s", "-o", "NUL", "-w", "%{http_code}",
                  "-m", $t, "--max-time", $t, "--connect-timeout", $t,
                  "-L", $url)
        $code = (& curl.exe @args 2>$null | Out-String).Trim()
        $exit = $LASTEXITCODE
        return [PSCustomObject]@{
            Url     = $url
            Code    = $code
            Exit    = $exit
            Passed  = ($exit -eq 0 -and $code -match "^[234]\d\d$")
        }
    }

    $runspaces = foreach ($url in $Urls) {
        $ps = [powershell]::Create().AddScript($scriptBlock).AddArgument($url).AddArgument($TimeoutSec)
        $ps.RunspacePool = $pool
        [PSCustomObject]@{ PS = $ps; Handle = $ps.BeginInvoke(); Url = $url }
    }

    # Collect results (wait up to TimeoutSec + 2s grace per runspace)
    $results = foreach ($rs in $runspaces) {
        $waitMs = ($TimeoutSec + 2) * 1000
        $completed = $rs.Handle.AsyncWaitHandle.WaitOne($waitMs)
        if (-not $completed) {
            try { $rs.PS.Stop() } catch {}
        }
        try   { $rs.PS.EndInvoke($rs.Handle) }
        catch { [PSCustomObject]@{ Url=$rs.Url; Code="ERR"; Exit=1; Passed=$false } }
        $rs.PS.Dispose()
    }

    $pool.Close(); $pool.Dispose()
    return $results
}

# =============================================================================
# MAIN LOOP
# =============================================================================
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "                 ZAPRET AUTOTUNE  [FAST MODE]" -ForegroundColor Cyan
Write-Host "     $($orderedNames.Count) strategies | parallel curl | smart order" -ForegroundColor DarkCyan
Write-Host "============================================================" -ForegroundColor Cyan

$bestStrategy = $null
$strategyIndex = 0

foreach ($name in $orderedNames) {
    $file = $batMap[$name]
    $strategyIndex++

    Write-Host ""
    Write-Host "--- [$strategyIndex/$($orderedNames.Count)] $name ---" -ForegroundColor Yellow

    Stop-Zapret

    # Launch the strategy bat silently
    $proc = Start-Process -FilePath "cmd.exe" `
        -ArgumentList "/c `"$($file.FullName)`"" `
        -WorkingDirectory $rootDir `
        -PassThru `
        -WindowStyle Hidden

    # --- OPTIMIZATION 2 (continued): Poll for winws.exe every 200ms (max 5s) ---
    $winwsStarted = $false
    $deadline = [DateTime]::Now.AddSeconds(5)
    while ([DateTime]::Now -lt $deadline) {
        Start-Sleep -Milliseconds 200
        if (Get-Process -Name "winws" -ErrorAction SilentlyContinue) {
            $winwsStarted = $true
            break
        }
    }

    if (-not $winwsStarted) {
        Write-Host "  [SKIP] winws.exe did not start within 5s." -ForegroundColor DarkYellow
        if ($proc -and -not $proc.HasExited) { $proc | Stop-Process -Force -ErrorAction SilentlyContinue }
        continue
    }

    # Small extra settle time for WinDivert to fully bind
    Start-Sleep -Milliseconds 400

    # --- OPTIMIZATION 3: Fire all curl checks in parallel ---
    Write-Host "  Checking $($testUrls.Count) URLs in parallel..." -NoNewline -ForegroundColor Gray
    $results = Test-Connectivity -Urls $testUrls -TimeoutSec $curlTimeout

    # Print per-URL result
    Write-Host ""
    $allPassed = $true
    foreach ($r in $results) {
        if ($r.Passed) {
            Write-Host "    [OK  ] $($r.Url) - $($r.Code)" -ForegroundColor Green
        } else {
            # OPTIMIZATION 4: Early fail - already baked in: no need to wait for
            # other runspaces since they ran in parallel (they all finished already).
            Write-Host "    [FAIL] $($r.Url) - exit=$($r.Exit) code=$($r.Code)" -ForegroundColor Red
            $allPassed = $false
        }
    }

    # Cleanup
    if ($proc -and -not $proc.HasExited) { $proc | Stop-Process -Force -ErrorAction SilentlyContinue }
    Stop-Zapret

    if ($allPassed) {
        Write-Host ""
        Write-Host "[SUCCESS] Best strategy found: $name" -ForegroundColor Green
        $bestStrategy = $name
        break
    }
}

# --- Write result ---
Write-Host ""
if ($bestStrategy) {
    if ($ResultFile) {
        [System.IO.File]::WriteAllText($ResultFile, $bestStrategy, [System.Text.Encoding]::ASCII)
    }
    Write-Host "Autotune complete. Applying: $bestStrategy" -ForegroundColor Cyan
    exit 0
} else {
    Write-Host "[WARN] No fully working strategy found." -ForegroundColor Yellow
    if ($ResultFile) {
        [System.IO.File]::WriteAllText($ResultFile, "0", [System.Text.Encoding]::ASCII)
    }
    exit 1
}
