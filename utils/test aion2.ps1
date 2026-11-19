# Separate Discord + AION 2 ALT diagnostic. Windows PowerShell 5.1.
# TCP handshake time is NOT in-game ping and cannot prove AION login works.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$configFile = Join-Path $PSScriptRoot 'targets-aion2.txt'
$resultDir = Join-Path $PSScriptRoot 'test results'
$previous = @()
$cycling = $false
function Snapshot-Winws {
    @(Get-CimInstance Win32_Process -Filter "Name='winws.exe'" |
      Select-Object ProcessId,ExecutablePath,CommandLine)
}
function Stop-Winws {
    Get-Process winws -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 400
}
function Restore-Winws($items) {
    foreach ($p in $items) {
        if (-not $p.ExecutablePath -or -not $p.CommandLine) { continue }
        $exe = $p.ExecutablePath
        $line = $p.CommandLine.Trim()
        $args = $null
        if ($line -match '^\s*"[^"]+"\s+(.*)$') { $args = $matches[1] }
        elseif ($line.StartsWith($exe, [StringComparison]::OrdinalIgnoreCase)) {
            $args = $line.Substring($exe.Length).Trim()
        }
        if ($args) {
            try { Start-Process -FilePath $exe -ArgumentList $args -WorkingDirectory (Split-Path $exe -Parent) -WindowStyle Minimized | Out-Null }
            catch { Write-Warning "Failed to restore original winws process: $_" }
        } else { Write-Warning 'Could not parse original winws command line; manual restart required.' }
    }
}
function Tcp-Ms($address,$port,$timeout) {
    $client = New-Object Net.Sockets.TcpClient
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        $task = $client.ConnectAsync($address,$port)
        if (-not $task.Wait($timeout)) { return $null }
        if ($client.Connected) { return [math]::Round($timer.Elapsed.TotalMilliseconds,1) }
    } catch {} finally { $client.Close(); $timer.Stop() }
    return $null
}
function Discord-Check($url) {
    try {
        $output = & curl.exe --silent --location --output NUL --connect-timeout 3 --max-time 6 --write-out '%{http_code}' $url 2>$null
        $rc = $LASTEXITCODE
        $code = 0
        [void][int]::TryParse((@($output) -join '').Trim(),[ref]$code)
        return (($rc -eq 0) -and ($code -ge 200) -and ($code -lt 500))
    } catch { return $false }
}
try {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run service.bat as administrator.' }
    if (Get-Service zapret -ErrorAction SilentlyContinue) { throw 'Remove installed zapret service before testing ALT files.' }
    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) { throw 'curl.exe is not available.' }
    if (Get-Process Aion2 -ErrorAction SilentlyContinue) { throw 'Close AION 2 before cycling strategies.' }
    $settings = @{}
    if (Test-Path $configFile) {
        foreach ($line in Get-Content $configFile) {
            if ($line -match '^\s*([A-Z_0-9]+)\s*=\s*(.*?)\s*$') {
                $settings[$matches[1]] = $matches[2].Trim().Trim('"')
            }
        }
    }
    $address = $settings['AION2_HOST']
    if (-not $address) { $address = (Read-Host 'Confirmed AION 2 server IP or hostname').Trim() }
    if (-not $address -or $address -notmatch '^[a-zA-Z0-9][a-zA-Z0-9.-]*$' -or $address.Contains('..')) {
        throw 'AION2_HOST missing or invalid. Do not use an unverified address.'
    }
    $port = 13328
    if ($settings['AION2_PORT']) {
        if (-not [int]::TryParse($settings['AION2_PORT'],[ref]$port) -or $port -lt 1 -or $port -gt 65535) { throw 'Invalid AION2_PORT.' }
    }
    $samples = 8
    if ($settings['TCP_SAMPLES']) {
        if (-not [int]::TryParse($settings['TCP_SAMPLES'],[ref]$samples) -or $samples -lt 3 -or $samples -gt 100) { throw 'Invalid TCP_SAMPLES (3..100).' }
    }
    $files = @(Get-ChildItem -Path $root -Filter 'general*.bat' -File | Sort-Object Name)
    if (-not $files.Count) { throw 'No general*.bat files found.' }
    $previous = @(Snapshot-Winws)
    if (@($previous | Where-Object { -not $_.ExecutablePath -or -not $_.CommandLine }).Count) {
        throw 'Cannot safely snapshot existing winws. Stop it and retry.'
    }
    New-Item -ItemType Directory -Path $resultDir -Force | Out-Null
    $cycling = $true
    $rows = @()
    $urls = @('https://discord.com','https://gateway.discord.gg','https://cdn.discordapp.com','https://updates.discord.com')
    $index = 0
    Write-Host 'Existing IPSet stays unchanged. AION2 TCP handshake is NOT gameplay ping.' -ForegroundColor Yellow
    foreach ($file in $files) {
        $index++
        Write-Host ('[{0}/{1}] {2}' -f $index,$files.Count,$file.Name) -ForegroundColor Cyan
        Stop-Winws
        $cmdArgs = '/c ""' + $file.FullName + '""'
        $proc = Start-Process cmd.exe -ArgumentList $cmdArgs -WorkingDirectory $root -WindowStyle Minimized -PassThru
        $running = $false
        for ($j=0; $j -lt 20; $j++) {
            Start-Sleep -Milliseconds 250
            if (Get-Process winws -ErrorAction SilentlyContinue) { $running = $true; break }
        }
        $discord = 0
        $times = @()
        if ($running) {
            foreach ($url in $urls) { if (Discord-Check $url) { $discord++ } }
            for ($j=0; $j -lt $samples; $j++) {
                $time = Tcp-Ms $address $port 1800
                if ($null -ne $time) { $times += [double]$time }
                Start-Sleep -Milliseconds 150
            }
        }
        $average = $null; $p95 = $null
        if ($times.Count) {
            $sorted = @($times | Sort-Object)
            $average = [math]::Round(($times | Measure-Object -Average).Average,1)
            $p95 = $sorted[[math]::Max(0,[math]::Ceiling($sorted.Count * 0.95)-1)]
        }
        $row = [pscustomobject]@{
            Config=$file.Name; WinwsStarted=$running; DiscordOK=$discord; DiscordTotal=$urls.Count
            AionTcpSuccessPct=[math]::Round(100*$times.Count/$samples,1)
            AionTcpAvgMs=$average; AionTcpP95Ms=$p95
            Target=('{0}:{1}' -f $address,$port)
        }
        $rows += $row
        Write-Host ('Discord {0}/4; AION TCP {1}/{2}; avg={3}; p95={4}' -f $discord,$times.Count,$samples,$average,$p95)
    }
    $path = Join-Path $resultDir ('aion2-discord-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.csv')
    $rows | Export-Csv -Path $path -NoTypeInformation -Encoding UTF8
    $rank = @($rows | Sort-Object @{Expression='DiscordOK';Descending=$true},@{Expression='AionTcpSuccessPct';Descending=$true},@{Expression='AionTcpP95Ms';Descending=$false})
    $rank | Select-Object -First 15 Config,DiscordOK,AionTcpSuccessPct,AionTcpAvgMs,AionTcpP95Ms | Format-Table -AutoSize | Out-Host
    Write-Host ('Saved: ' + $path) -ForegroundColor Green
    Write-Host 'Ranking is provisional: verify real in-game connection, ping, loss and DPS.' -ForegroundColor Yellow
} catch {
    Write-Host ('[ERROR] ' + $_.Exception.Message) -ForegroundColor Red
} finally {
    if ($cycling) { Stop-Winws; Restore-Winws $previous }
    [void](Read-Host 'Press Enter to close')
}
