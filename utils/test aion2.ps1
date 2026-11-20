# Discord + AION 2 diagnostics (Windows PowerShell 5.1)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'aion2-checks.ps1')
$configFile = Join-Path $PSScriptRoot 'targets-aion2.txt'
$resultDir = Join-Path $PSScriptRoot 'test results'
$previous = @()
$cycling = $false

function Snapshot-Winws {
    @(Get-CimInstance Win32_Process -Filter "Name='winws.exe'" |
      Select-Object ProcessId,ExecutablePath,CommandLine)
}
function Stop-Winws {
    Get-Process -Name winws -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
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
            try {
                Start-Process -FilePath $exe -ArgumentList $args -WorkingDirectory (Split-Path $exe -Parent) -WindowStyle Minimized | Out-Null
            } catch { Write-Warning "Could not restore winws process: $_" }
        } else { Write-Warning 'Could not parse original winws command line. Manual restart required.' }
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
        return ($rc -eq 0 -and $code -ge 200 -and $code -lt 500)
    } catch { return $false }
}
function Read-Config {
    $settings = @{}
    if (Test-Path $configFile) {
        foreach ($line in Get-Content $configFile) {
            if ($line -match '^\s*([A-Z_0-9]+)\s*=\s*(.*?)\s*$') {
                $settings[$matches[1]] = $matches[2].Trim().Trim('"')
            }
        }
    }
    return $settings
}
try {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run service.bat as Administrator.' }
    if (Get-Service -Name zapret -ErrorAction SilentlyContinue) { throw 'Remove installed zapret service before cycling ALT configurations.' }
    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) { throw 'curl.exe missing.' }
    if (Get-Process -Name Aion2 -ErrorAction SilentlyContinue) { throw 'Close AION 2 before cycling ALT configurations.' }

    $settings = Read-Config
    $address = $settings['AION2_HOST']
    if (-not $address) { $address = (Read-Host 'Enter CONFIRMED AION 2 IP or hostname').Trim() }
    if (-not $address -or $address -notmatch '^[a-zA-Z0-9][a-zA-Z0-9.-]*$' -or $address.Contains('..')) {
        throw 'Invalid AION2_HOST. Find the real endpoint from an active game session first.'
    }
    $port = 13328
    if ($settings['AION2_PORT']) {
        if (-not [int]::TryParse($settings['AION2_PORT'],[ref]$port) -or $port -lt 1 -or $port -gt 65535) {
            throw 'Invalid AION2_PORT.'
        }
    }
    $samples = 8
    if ($settings['TCP_SAMPLES']) {
        if (-not [int]::TryParse($settings['TCP_SAMPLES'],[ref]$samples) -or $samples -lt 3 -or $samples -gt 100) {
            throw 'Invalid TCP_SAMPLES (3..100).'
        }
    }

    $ipsetPath = Join-Path $root 'lists\ipset-all.txt'
    if (-not (Test-Path $ipsetPath)) { throw 'IPSet file not found.' }
    $ipsetState = Test-AionIPSet -Address $address -Lines @(Get-Content $ipsetPath)
    if ($ipsetState -eq 'none' -or $ipsetState -eq 'excluded') {
        throw ('Game IP is not in current IPSet (' + $ipsetState + '). Update IPSet first.')
    }

    $gamePath = Join-Path $PSScriptRoot 'game_filter.enabled'
    if (-not (Test-Path $gamePath)) { throw 'Enable Game Filter TCP before testing.' }
    $mode = ''
    $gameTcp = '1024-65535'
    foreach ($line in Get-Content $gamePath) {
        if ($line -match '^\s*mode\s*=\s*(.*)$') { $mode = $matches[1].Trim() }
        if ($line -match '^\s*tcp\s*=\s*(.*)$') { $gameTcp = $matches[1].Trim() }
    }
    if ($mode -ne 'tcp' -and $mode -ne 'all') { throw 'Game Filter must include TCP.' }
    if (-not (Test-AionPortInRange -Port $port -Ranges $gameTcp)) { throw 'Game Filter does not cover the target TCP port.' }

    $files = @(Get-ChildItem -Path $root -Filter 'general*.bat' -File | Sort-Object Name)
    if ($files.Count -eq 0) { throw 'No general*.bat configurations found.' }
    $previous = @(Snapshot-Winws)
    if (@($previous | Where-Object { -not $_.ExecutablePath -or -not $_.CommandLine }).Count -gt 0) {
        throw 'Could not snapshot existing winws. Stop it manually first.'
    }

    New-Item -ItemType Directory -Path $resultDir -Force | Out-Null
    $cycling = $true
    $urls = @('https://discord.com','https://gateway.discord.gg','https://cdn.discordapp.com','https://updates.discord.com')
    $rows = @()

    Write-Host 'Direct TCP baseline with winws stopped...' -ForegroundColor Cyan
    Stop-Winws
    $baselineTimes = @()
    for ($k = 0; $k -lt $samples; $k++) {
        $ms = Tcp-Ms $address $port 1800
        if ($null -ne $ms) { $baselineTimes += [double]$ms }
        Start-Sleep -Milliseconds 150
    }
    $baseline = Get-AionStats -Measurements $baselineTimes -Attempts $samples
    Write-Host ('Direct TCP: {0}/{1}, P95: {2} ms' -f $baseline.Count,$samples,$baseline.P95Ms)

    $index = 0
    foreach ($file in $files) {
        $index++
        Write-Host ('[{0}/{1}] {2}' -f $index,$files.Count,$file.Name) -ForegroundColor Cyan
        Stop-Winws
        $cmdArgs = '/c ""' + $file.FullName + '""'
        [void](Start-Process -FilePath cmd.exe -ArgumentList $cmdArgs -WorkingDirectory $root -WindowStyle Minimized -PassThru)
        $running = $false
        for ($j = 0; $j -lt 20; $j++) {
            Start-Sleep -Milliseconds 250
            if (Get-Process -Name winws -ErrorAction SilentlyContinue) { $running = $true; break }
        }
        $discord = 0
        $times = @()
        if ($running) {
            foreach ($url in $urls) { if (Discord-Check $url) { $discord++ } }
            for ($j = 0; $j -lt $samples; $j++) {
                $ms = Tcp-Ms $address $port 1800
                if ($null -ne $ms) { $times += [double]$ms }
                Start-Sleep -Milliseconds 150
            }
        }
        $stats = Get-AionStats -Measurements $times -Attempts $samples
        $row = [pscustomobject]@{
            Config = $file.Name
            WinwsStarted = $running
            DiscordOK = $discord
            DiscordTotal = $urls.Count
            AionTcpSuccessPct = $stats.SuccessPct
            AionTcpAvgMs = $stats.AvgMs
            AionTcpP95Ms = $stats.P95Ms
            Eligible = ($running -and $discord -eq $urls.Count -and $stats.Count -eq $samples)
            Target = ('{0}:{1}' -f $address,$port)
        }
        $rows += $row
        Write-Host ('Discord: {0}/4, game TCP: {1}/{2}, avg={3}, P95={4}' -f $discord,$stats.Count,$samples,$stats.AvgMs,$stats.P95Ms)
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $csvPath = Join-Path $resultDir ('aion2-discord-' + $stamp + '.csv')
    $baselinePath = Join-Path $resultDir ('aion2-baseline-' + $stamp + '.csv')
    $rows | Export-Csv -Path $csvPath -Encoding UTF8 -NoTypeInformation
    $baseline | Export-Csv -Path $baselinePath -Encoding UTF8 -NoTypeInformation
    $ranked = @(Get-AionRank -Rows $rows)
    $ranked | Select-Object Config,DiscordOK,AionTcpSuccessPct,AionTcpAvgMs,AionTcpP95Ms,Eligible | Format-Table -AutoSize | Out-Host
    Write-Host ('Results: ' + $csvPath) -ForegroundColor Green
    Write-Host 'NOTE: TCP handshake is not an AION gameplay ping or proof of DPI bypass.' -ForegroundColor Yellow
} catch {
    Write-Host ('[ERROR] ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Yellow
} finally {
    if ($cycling) {
        Stop-Winws
        Restore-Winws $previous
    }
    [void](Read-Host 'Press Enter to close')
}
