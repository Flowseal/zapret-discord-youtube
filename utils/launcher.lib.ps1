#Requires -Version 5.1
<#
.SYNOPSIS
  Shared logic for the zapret-discord-youtube launcher (CLI + GUI).
.DESCRIPTION
  Pure-ish library: no console writes, no [Console]::ReadLine prompts. The
  caller (CLI or GUI) supplies a $Script:LogSink scriptblock — see
  Write-LauncherLog.
#>

$ErrorActionPreference = 'Stop'

# ============================================================================
# Paths
# ============================================================================
$Script:UtilsDir         = $PSScriptRoot
$Script:RepoRoot         = Split-Path -Parent $PSScriptRoot
$Script:ListsDir         = Join-Path $RepoRoot 'lists'
$Script:BinDir           = Join-Path $RepoRoot 'bin'
$Script:CustomDir        = Join-Path $RepoRoot 'custom-vpn'
$Script:ConfigPath       = Join-Path $RepoRoot 'launcher.conf'
$Script:PacPath          = Join-Path $UtilsDir  'launcher.pac'
$Script:PacServerScript  = Join-Path $UtilsDir  'launcher.pacserver.ps1'
$Script:PacServerPidFile = Join-Path $RepoRoot  'launcher.pac-server.pid'
$Script:DefaultPacPort   = 27289
$Script:Version          = '1.2.1'

# ============================================================================
# Service catalogues
# ============================================================================
# DPI services: their domains go through zapret (winws.exe DPI desync). Toggle
# is reflected in lists/list-general-user.txt which every general*.bat already
# includes via --hostlist. AlwaysOn lists are referenced by upstream strategies
# directly (list-google.txt / list-general.txt) and cannot be disabled here.
$Script:Services = [ordered]@{
    youtube  = @{ Name='YouTube';                            File='list-google.txt';   AlwaysOn=$true;  DefaultOn=$true  }
    discord  = @{ Name='Discord / Cloudflare / Twitch chat'; File='list-general.txt';  AlwaysOn=$true;  DefaultOn=$true  }
    meta     = @{ Name='Meta (Instagram/Facebook/Threads)';  File='list-meta.txt';     AlwaysOn=$false; DefaultOn=$true  }
    telegram = @{ Name='Telegram (web/CDN)';                 File='list-telegram.txt'; AlwaysOn=$false; DefaultOn=$true  }
    x        = @{ Name='X / Twitter';                        File='list-x.txt';        AlwaysOn=$false; DefaultOn=$true  }
    linkedin = @{ Name='LinkedIn';                           File='list-linkedin.txt'; AlwaysOn=$false; DefaultOn=$true  }
    signal   = @{ Name='Signal';                             File='list-signal.txt';   AlwaysOn=$false; DefaultOn=$true  }
    tiktok   = @{ Name='TikTok';                             File='list-tiktok.txt';   AlwaysOn=$false; DefaultOn=$true  }
    reddit   = @{ Name='Reddit';                             File='list-reddit.txt';   AlwaysOn=$false; DefaultOn=$false }
    patreon  = @{ Name='Patreon';                            File='list-patreon.txt';  AlwaysOn=$false; DefaultOn=$false }
    notion   = @{ Name='Notion (DPI)';                       File='list-notion.txt';   AlwaysOn=$false; DefaultOn=$false }
    imgur    = @{ Name='Imgur';                              File='list-imgur.txt';    AlwaysOn=$false; DefaultOn=$false }
    spotify  = @{ Name='Spotify (web)';                      File='list-spotify.txt';  AlwaysOn=$false; DefaultOn=$false }
    news     = @{ Name='News (BBC/DW/Meduza/...)';           File='list-news.txt';     AlwaysOn=$false; DefaultOn=$false }
}

# Geo services: server-side IP geo-blocked. zapret cannot help — DPI bypass on
# RU side does nothing if the destination refuses RU IPs. Their domains are
# routed via Cloudflare WARP (proxy mode SOCKS5 127.0.0.1:40000) using a PAC
# file. Toggleable from the GUI / CLI.
$Script:GeoServices = [ordered]@{
    openai  = @{ Name='ChatGPT / OpenAI';   File='geo-openai.txt';  DefaultOn=$true  }
    claude  = @{ Name='Claude / Anthropic'; File='geo-claude.txt';  DefaultOn=$true  }
    gemini  = @{ Name='Google Gemini / AI Studio'; File='geo-gemini.txt'; DefaultOn=$false }
    cursor  = @{ Name='Cursor';             File='geo-cursor.txt';  DefaultOn=$false }
    copilot = @{ Name='GitHub Copilot';     File='geo-copilot.txt'; DefaultOn=$false }
    spotify = @{ Name='Spotify (geo)';      File='geo-spotify.txt'; DefaultOn=$false }
    notion  = @{ Name='Notion (geo)';       File='geo-notion.txt';  DefaultOn=$false }
}

# ============================================================================
# Logging — overridable
# ============================================================================
$Script:LogSink = $null
function Write-LauncherLog {
    param([string]$Message, [string]$Color = 'White')
    if ($Script:LogSink) {
        try { & $Script:LogSink $Message $Color } catch { }
    } else {
        Write-Host "  $Message" -ForegroundColor $Color
    }
}

# ============================================================================
# Config persistence
# ============================================================================
function Get-DefaultConfig {
    $cfg = [ordered]@{}
    $cfg.strategy        = 'general (FAKE TLS AUTO).bat'
    $cfg.warp_mode       = 'proxy'
    $cfg.warp_autostart  = '1'
    $cfg.geo_routing     = '1'
    $cfg.pac_port        = "$DefaultPacPort"
    foreach ($key in $Services.Keys) {
        $cfg["service_$key"] = if ($Services[$key].DefaultOn) { '1' } else { '0' }
    }
    foreach ($key in $GeoServices.Keys) {
        $cfg["geo_$key"] = if ($GeoServices[$key].DefaultOn) { '1' } else { '0' }
    }
    $cfg
}

function Read-Config {
    $cfg = Get-DefaultConfig
    if (Test-Path $ConfigPath) {
        foreach ($line in Get-Content -LiteralPath $ConfigPath -Encoding UTF8) {
            $trim = $line.Trim()
            if (-not $trim -or $trim.StartsWith('#')) { continue }
            $eq = $trim.IndexOf('=')
            if ($eq -lt 1) { continue }
            $k = $trim.Substring(0, $eq).Trim()
            $v = $trim.Substring($eq + 1).Trim()
            $cfg[$k] = $v
        }
    }
    $cfg
}

function Write-Utf8NoBom([string]$path, [string[]]$lines) {
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($path, [string[]]$lines, $enc)
}

function Save-Config([hashtable]$cfg) {
    $lines = @('# zapret-discord-youtube launcher config — managed automatically.')
    foreach ($k in $cfg.Keys) {
        $lines += "$k=$($cfg[$k])"
    }
    Write-Utf8NoBom $ConfigPath $lines
}

# ============================================================================
# Reusable helpers
# ============================================================================
function Read-DomainList([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in Get-Content -LiteralPath $path -Encoding UTF8) {
        $t = $line.Trim()
        if ($t -and -not $t.StartsWith('#')) { $null = $out.Add($t) }
    }
    @($out)
}

function Test-WinwsRunning {
    @(Get-Process -Name 'winws' -ErrorAction SilentlyContinue).Count -gt 0
}

function Test-ServiceInstalled([string]$name) {
    $null -ne (Get-Service -Name $name -ErrorAction SilentlyContinue)
}

function Test-ServiceRunning([string]$name) {
    $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
    $svc -and $svc.Status -eq 'Running'
}

# ============================================================================
# DPI services -> rewrite list-general-user.txt
# ============================================================================
function Apply-Services([hashtable]$cfg) {
    $target = Join-Path $ListsDir 'list-general-user.txt'
    $domains = New-Object System.Collections.Generic.List[string]

    foreach ($key in $Services.Keys) {
        $svc = $Services[$key]
        if ($svc.AlwaysOn) { continue }
        if ($cfg["service_$key"] -ne '1') { continue }
        foreach ($d in (Read-DomainList (Join-Path $ListsDir $svc.File))) {
            $null = $domains.Add($d)
        }
    }

    $custom = Join-Path $ListsDir 'list-custom.txt'
    foreach ($d in (Read-DomainList $custom)) { $null = $domains.Add($d) }

    if ($domains.Count -eq 0) {
        Write-Utf8NoBom $target @('domain.example.abc')
    } else {
        Write-Utf8NoBom $target @($domains | Sort-Object -Unique)
    }
}

# ============================================================================
# Strategy enumeration
# ============================================================================
function Get-StrategyFiles {
    Get-ChildItem -LiteralPath $RepoRoot -Filter '*.bat' |
        Where-Object { $_.Name -notlike 'service*' -and $_.Name -notlike 'launcher*' } |
        Sort-Object {
            [Regex]::Replace($_.Name, '(\d+)', { param($m) $m.Value.PadLeft(8, '0') })
        } |
        Select-Object -ExpandProperty Name
}

# ============================================================================
# Geo routing — PAC file for selective WARP
# ============================================================================
function Get-GeoDomainsForConfig([hashtable]$cfg) {
    $domains = New-Object System.Collections.Generic.List[string]
    foreach ($key in $GeoServices.Keys) {
        if ($cfg["geo_$key"] -ne '1') { continue }
        foreach ($d in (Read-DomainList (Join-Path $ListsDir $GeoServices[$key].File))) {
            $null = $domains.Add($d.ToLowerInvariant())
        }
    }
    # User-provided extras (one per line in lists/geo-custom.txt).
    $extra = Join-Path $ListsDir 'geo-custom.txt'
    foreach ($d in (Read-DomainList $extra)) { $null = $domains.Add($d.ToLowerInvariant()) }
    @($domains | Sort-Object -Unique)
}

function Build-PacScript([string[]]$domains, [string]$proxyTarget = 'SOCKS5 127.0.0.1:40000; SOCKS 127.0.0.1:40000; DIRECT') {
    # JS array literal of domains.
    $jsArr = ($domains | ForEach-Object {
        '"' + ($_ -replace '\\', '\\' -replace '"', '\"') + '"'
    }) -join ", "
    $pac = @"
// zapret-discord-youtube launcher PAC — auto-generated.
// Routes geo-blocked domains via Cloudflare WARP SOCKS5; everything else direct
// (so zapret/winws can do its DPI desync on the rest).
function FindProxyForURL(url, host) {
    host = (host || '').toLowerCase();
    var domains = [$jsArr];
    for (var i = 0; i < domains.length; i++) {
        var d = domains[i];
        if (host === d) { return '$proxyTarget'; }
        if (host.length > d.length &&
            host.charAt(host.length - d.length - 1) === '.' &&
            host.substring(host.length - d.length) === d) {
            return '$proxyTarget';
        }
    }
    return 'DIRECT';
}
"@
    $pac
}

function Write-PacFile([hashtable]$cfg) {
    $domains = Get-GeoDomainsForConfig $cfg
    $pac = Build-PacScript -domains $domains
    Write-Utf8NoBom $PacPath @($pac)
    return @{ Path = $PacPath; DomainCount = $domains.Count }
}

function Get-PacPort([hashtable]$cfg) {
    $p = 0
    if ($cfg -and [int]::TryParse([string]$cfg.pac_port, [ref]$p) -and $p -gt 0) { return $p }
    return $DefaultPacPort
}

function Get-PacFileUrl([hashtable]$cfg) {
    # Modern Chrome/Edge handle file:// PAC URLs unreliably (depends on version
    # and security policy). Serve the PAC over a tiny localhost HTTP server
    # instead — universally supported.
    $port = Get-PacPort $cfg
    "http://127.0.0.1:$port/launcher.pac"
}

function Test-PacServerRunning {
    if (-not (Test-Path -LiteralPath $PacServerPidFile)) { return $false }
    $procId = 0
    try { $procId = [int](Get-Content -LiteralPath $PacServerPidFile -Raw -ErrorAction Stop).Trim() } catch { return $false }
    if ($procId -le 0) { return $false }
    $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
    return [bool]$proc
}

function Stop-PacServer {
    $procId = 0
    if (Test-Path -LiteralPath $PacServerPidFile) {
        try { $procId = [int](Get-Content -LiteralPath $PacServerPidFile -Raw).Trim() } catch { $procId = 0 }
    }
    if ($procId -gt 0) {
        try {
            $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
            if ($proc) {
                Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
                # Wait for actual exit so subsequent rebind doesn't race.
                $deadline = (Get-Date).AddSeconds(2)
                while ((Get-Date) -lt $deadline) {
                    if (-not (Get-Process -Id $procId -ErrorAction SilentlyContinue)) { break }
                    Start-Sleep -Milliseconds 80
                }
            }
        } catch { }
    }
    Remove-Item -LiteralPath $PacServerPidFile -ErrorAction SilentlyContinue
}

function Test-PortInUse([int]$port) {
    $tcp = $null
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $task = $tcp.ConnectAsync('127.0.0.1', $port)
        return ($task.Wait(300) -and $tcp.Connected)
    } catch {
        return $false
    } finally {
        if ($tcp) { try { $tcp.Close() } catch { } }
    }
}

function Wait-PacServerReady([int]$port, [int]$timeoutMs = 3000) {
    # Probe the listener with raw HTTP — works on PS5.1 (Windows) and pwsh on
    # Linux without the Invoke-WebRequest stream-buffering quirk.
    $deadline = (Get-Date).AddMilliseconds($timeoutMs)
    while ((Get-Date) -lt $deadline) {
        $tcp = $null
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $task = $tcp.ConnectAsync('127.0.0.1', $port)
            if ($task.Wait(500) -and $tcp.Connected) {
                $stream = $tcp.GetStream()
                $stream.ReadTimeout  = 1500
                $stream.WriteTimeout = 1500
                $req = "GET /launcher.pac HTTP/1.0`r`nHost: 127.0.0.1`r`nConnection: close`r`n`r`n"
                $bytes = [Text.Encoding]::ASCII.GetBytes($req)
                $stream.Write($bytes, 0, $bytes.Length)
                $stream.Flush()
                $reader = New-Object System.IO.StreamReader($stream, [Text.Encoding]::UTF8)
                $body = $reader.ReadToEnd()
                if ($body -match 'FindProxyForURL') { return $true }
            }
        } catch { }
        finally {
            if ($tcp) { try { $tcp.Close() } catch { } }
        }
        Start-Sleep -Milliseconds 120
    }
    return $false
}

function Start-PacServer([hashtable]$cfg) {
    Stop-PacServer
    if (-not (Test-Path -LiteralPath $PacServerScript)) {
        throw "PAC server script not found: $PacServerScript"
    }
    if (-not (Test-Path -LiteralPath $PacPath)) {
        # Generate placeholder PAC so listener has something to serve immediately.
        Write-PacFile $cfg | Out-Null
    }
    $port = Get-PacPort $cfg
    # If the configured port is occupied by something OTHER than us (since we
    # just stopped our previous server), refuse to silently fight it.
    if (Test-PortInUse $port) {
        throw "PAC port $port is already in use. Change pac_port in launcher.conf or stop the conflicting service."
    }

    # Avoid clobbering the automatic $args variable.
    $psArgs = @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass',
                '-File', $PacServerScript, '-PacPath', $PacPath, '-Port', $port)
    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs -WindowStyle Hidden -PassThru
    if (-not $proc) { throw 'Failed to spawn PAC server process.' }

    Set-Content -LiteralPath $PacServerPidFile -Value $proc.Id -Encoding ASCII

    # Probe the listener instead of a blind sleep — detect bind failures fast.
    if (-not (Wait-PacServerReady -port $port -timeoutMs 3000)) {
        # Listener never came up — clean up the orphan process + PID file.
        try {
            $alive = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
            if ($alive) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
        } catch { }
        Remove-Item -LiteralPath $PacServerPidFile -ErrorAction SilentlyContinue
        throw "PAC server failed to start on port $port within 3s."
    }

    return @{ Port = $port; Pid = $proc.Id; Url = "http://127.0.0.1:$port/launcher.pac" }
}

function Enable-PacAutoConfig([hashtable]$cfg) {
    $url = Get-PacFileUrl $cfg
    $regKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    Set-ItemProperty -Path $regKey -Name AutoConfigURL -Value $url
    # Disable static proxy if it was set; AutoConfigURL takes precedence in some
    # browsers but better to be explicit.
    try { Set-ItemProperty -Path $regKey -Name ProxyEnable -Value 0 -Type DWord -ErrorAction SilentlyContinue } catch { }
    return $url
}

function Disable-PacAutoConfig {
    $regKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    try { Remove-ItemProperty -Path $regKey -Name AutoConfigURL -ErrorAction SilentlyContinue } catch { }
}

function Test-PacEnabled([hashtable]$cfg) {
    $regKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $u = (Get-ItemProperty -Path $regKey -Name AutoConfigURL -ErrorAction SilentlyContinue).AutoConfigURL
    if (-not $u) { return $false }
    if ($cfg) {
        return ($u -ieq (Get-PacFileUrl $cfg))
    }
    return ($u -match '^http://127\.0\.0\.1:\d+/launcher\.pac$')
}

# ============================================================================
# Cloudflare WARP
# ============================================================================
function Get-WarpCli {
    foreach ($base in @(${env:ProgramFiles}, ${env:ProgramFiles(x86)})) {
        if (-not $base) { continue }
        $p = Join-Path $base 'Cloudflare\Cloudflare WARP\warp-cli.exe'
        if (Test-Path $p) { return $p }
    }
    $cmd = Get-Command 'warp-cli.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Invoke-WarpCli {
    param([Parameter(ValueFromRemainingArguments=$true)] [string[]]$ArgList)
    $exe = Get-WarpCli
    if (-not $exe) { throw 'warp-cli not found.' }
    & $exe @ArgList 2>&1
}

# warp-cli status spawns a process and can take 50-300ms per call. The status
# updater fires every 3s, so we cache the result with a short TTL.
$Script:WarpStatusCache       = $null
$Script:WarpStatusCacheExpiry = [datetime]::MinValue

function Get-WarpStatus {
    param([switch]$Force)
    if (-not $Force -and $Script:WarpStatusCache -and (Get-Date) -lt $Script:WarpStatusCacheExpiry) {
        return $Script:WarpStatusCache
    }
    $exe = Get-WarpCli
    if (-not $exe) {
        $st = @{ Installed=$false; Connected=$false; Mode='unknown'; Raw='' }
    } else {
        $out = ''
        try { $out = (& $exe 'status' 2>&1) -join "`n" } catch { $out = "$_" }
        $connected = ($out -match '(?im)^\s*Status(?:\s+update)?\s*:\s*(Connected|Connecting)\b')
        $st = @{ Installed=$true; Connected=$connected; Raw=$out }
    }
    $Script:WarpStatusCache       = $st
    $Script:WarpStatusCacheExpiry = (Get-Date).AddSeconds(5)
    return $st
}

function Reset-WarpStatusCache {
    $Script:WarpStatusCache       = $null
    $Script:WarpStatusCacheExpiry = [datetime]::MinValue
}

function Set-WarpMode([string]$mode) {
    $exe = Get-WarpCli
    if (-not $exe) { throw 'warp-cli not found.' }
    # Some warp-cli versions: `warp-cli set-mode <mode>` (newer).
    # Older: `warp-cli mode <mode>`. Try new first, fall back to old.
    $err = $null
    try {
        & $exe 'set-mode' $mode 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "set-mode exit $LASTEXITCODE" }
    } catch {
        $err = $_
        try { & $exe 'mode' $mode 2>&1 | Out-Null } catch { throw $err }
    }
}

function Connect-Warp {
    Invoke-WarpCli 'connect' | Out-Null
    Reset-WarpStatusCache
}

function Disconnect-Warp {
    Invoke-WarpCli 'disconnect' | Out-Null
    Reset-WarpStatusCache
}

function Install-Warp {
    Write-LauncherLog 'Installing Cloudflare WARP via winget...' 'Yellow'
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        Write-LauncherLog 'winget is not available. Get installer from https://1.1.1.1/' 'Red'
        return $false
    }
    $wingetArgs = @(
        'install', '--id', 'Cloudflare.Warp', '-e',
        '--accept-package-agreements', '--accept-source-agreements'
    )
    & winget @wingetArgs 2>&1 | ForEach-Object { Write-LauncherLog $_ 'DarkGray' }
    Write-LauncherLog '' 'White'
    if (Get-WarpCli) {
        Write-LauncherLog 'WARP installed. Registering client (accepts ToS)...' 'Green'
        try { Invoke-WarpCli 'registration' 'new' 2>&1 | Out-Null } catch { }
        try { Invoke-WarpCli 'register' 2>&1 | Out-Null } catch { }
        return $true
    }
    Write-LauncherLog 'Install finished but warp-cli was not detected.' 'Yellow'
    return $false
}

function Install-WireGuard {
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        Write-LauncherLog 'winget not available — get installer from https://www.wireguard.com/install/' 'Yellow'
        return $false
    }
    & winget install -e --id WireGuard.WireGuard --accept-package-agreements --accept-source-agreements 2>&1 |
        ForEach-Object { Write-LauncherLog $_ 'DarkGray' }
    return $true
}

# ============================================================================
# WireGuard / system proxy
# ============================================================================
function Get-WireGuardExe {
    foreach ($base in @(${env:ProgramFiles}, ${env:ProgramFiles(x86)})) {
        if (-not $base) { continue }
        $p = Join-Path $base 'WireGuard\wireguard.exe'
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Get-WireGuardTunnels {
    @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'WireGuardTunnel$*' })
}

function Install-WireGuardTunnel([string]$confPath) {
    if (-not (Test-Path -LiteralPath $confPath)) {
        throw "File not found: $confPath"
    }
    $wg = Get-WireGuardExe
    if (-not $wg) { throw 'WireGuard for Windows is not installed.' }
    & $wg /installtunnelservice $confPath
}

function Stop-WireGuardTunnels {
    $tunnels = Get-WireGuardTunnels
    if (-not $tunnels) { return 0 }
    foreach ($t in $tunnels) {
        & sc.exe stop $t.Name | Out-Null
        & sc.exe delete $t.Name | Out-Null
    }
    return $tunnels.Count
}

function Set-SystemProxy([string]$proxy) {
    if (-not $proxy) { throw 'Proxy string required.' }
    $regKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    Set-ItemProperty -Path $regKey -Name ProxyServer -Value $proxy
    Set-ItemProperty -Path $regKey -Name ProxyEnable -Value 1 -Type DWord
    Set-ItemProperty -Path $regKey -Name ProxyOverride -Value '<local>'
    & netsh winhttp set proxy proxy-server="$proxy" bypass-list="<local>" | Out-Null
}

function Disable-SystemProxy {
    $regKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    Set-ItemProperty -Path $regKey -Name ProxyEnable -Value 0 -Type DWord
    & netsh winhttp reset proxy | Out-Null
}

function Get-SystemProxyStatus {
    $regKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $enabled = (Get-ItemProperty -Path $regKey -Name ProxyEnable -ErrorAction SilentlyContinue).ProxyEnable
    $server  = (Get-ItemProperty -Path $regKey -Name ProxyServer -ErrorAction SilentlyContinue).ProxyServer
    $auto    = (Get-ItemProperty -Path $regKey -Name AutoConfigURL -ErrorAction SilentlyContinue).AutoConfigURL
    @{ Enabled = ($enabled -eq 1); Server = $server; AutoConfigURL = $auto }
}

# ============================================================================
# Bypass control
# ============================================================================
function Stop-Bypass {
    if (-not (Test-WinwsRunning)) { return }
    Get-Process -Name 'winws' -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    # Wait for actual exit — Stop-Process is async. Up to 2s.
    $deadline = (Get-Date).AddSeconds(2)
    while ((Test-WinwsRunning) -and ((Get-Date) -lt $deadline)) {
        Start-Sleep -Milliseconds 100
    }
}

function Start-Bypass([hashtable]$cfg) {
    if (Test-ServiceRunning 'zapret') {
        return @{ Success=$false; Message='zapret service is RUNNING. Remove the service first or use service.bat.' }
    }
    Stop-Bypass
    Apply-Services $cfg

    $batPath = Join-Path $RepoRoot $cfg.strategy
    if (-not (Test-Path -LiteralPath $batPath)) {
        return @{ Success=$false; Message="Strategy file not found: $($cfg.strategy)" }
    }

    Write-LauncherLog "Starting strategy: $($cfg.strategy)" 'Green'
    & cmd.exe /c "call `"$batPath`""
    Start-Sleep -Seconds 2

    if (-not (Test-WinwsRunning)) {
        return @{ Success=$false; Message='winws.exe did not start. Check the strategy file or run diagnostics.' }
    }
    return @{ Success=$true; Message="Bypass started: $($cfg.strategy)" }
}

# ============================================================================
# Combined: zapret + WARP + PAC routing
# ============================================================================
function Start-Combined([hashtable]$cfg) {
    $result = @{
        Success      = $false
        Message      = ''
        Bypass       = $false
        Warp         = $false
        Pac          = $false
        Errors       = New-Object System.Collections.Generic.List[string]
        DomainCount  = 0
    }

    # 1. Start zapret.
    $r = Start-Bypass $cfg
    $result.Bypass  = [bool]$r.Success
    $result.Message = $r.Message
    $result.Success = [bool]$r.Success
    if (-not $r.Success) {
        $result.Errors.Add("zapret: $($r.Message)") | Out-Null
    }

    # 2. Optionally start WARP and apply PAC.
    if ($cfg.warp_autostart -eq '1') {
        $warp = Get-WarpStatus -Force
        if (-not $warp.Installed) {
            Write-LauncherLog 'WARP not installed — skipping WARP autostart and PAC routing.' 'DarkGray'
            $result.Errors.Add('warp: not installed') | Out-Null
        } else {
            try {
                Set-WarpMode 'proxy'
                if (-not $warp.Connected) {
                    Write-LauncherLog 'WARP: connecting (proxy mode 127.0.0.1:40000)...' 'Cyan'
                    Connect-Warp
                }
                # Poll up to 6s for Connected — handshake on cold start can take a moment.
                $deadline = (Get-Date).AddSeconds(6)
                $now = $warp
                while ((Get-Date) -lt $deadline) {
                    Start-Sleep -Milliseconds 400
                    $now = Get-WarpStatus -Force
                    if ($now.Connected) { break }
                }
                if ($now.Connected) {
                    $result.Warp = $true
                    Write-LauncherLog 'WARP connected.' 'Green'
                } else {
                    $result.Errors.Add('warp: connect did not report Connected within 6s') | Out-Null
                    Write-LauncherLog 'WARP: connect issued but status not Connected within 6s.' 'Yellow'
                }
            } catch {
                $result.Errors.Add("warp: $_") | Out-Null
                Write-LauncherLog "WARP autostart failed: $_" 'Yellow'
            }

            # PAC routing — only sensible if WARP proxy is up.
            if ($cfg.geo_routing -eq '1' -and $result.Warp) {
                try {
                    $info = Write-PacFile $cfg
                    $result.DomainCount = $info.DomainCount
                    $srv = Start-PacServer $cfg
                    Enable-PacAutoConfig $cfg | Out-Null
                    $result.Pac = $true
                    Write-LauncherLog ("PAC routing on: {0} domain(s) -> WARP, rest direct ({1})." -f $info.DomainCount, $srv.Url) 'Cyan'
                } catch {
                    $result.Errors.Add("pac: $_") | Out-Null
                    Write-LauncherLog "PAC setup failed: $_" 'Yellow'
                }
            } elseif ($cfg.geo_routing -eq '1' -and -not $result.Warp) {
                Write-LauncherLog 'PAC routing skipped: WARP is not connected.' 'DarkGray'
            }
        }
    }

    # Summary line.
    $parts = @()
    $parts += $(if ($result.Bypass) { 'zapret OK' } else { 'zapret FAILED' })
    if ($cfg.warp_autostart -eq '1') {
        $parts += $(if ($result.Warp) { 'WARP OK' } else { 'WARP off' })
        if ($cfg.geo_routing -eq '1') {
            $parts += $(if ($result.Pac) { "PAC OK ($($result.DomainCount))" } else { 'PAC off' })
        }
    }
    $result.Message = ($parts -join '   |   ')
    return $result
}

function Stop-Combined([hashtable]$cfg) {
    Stop-Bypass

    # Always disable PAC + kill server even if cfg.warp_autostart toggled off
    # since last Start, otherwise we leak state.
    if (Test-PacEnabled $cfg) {
        Disable-PacAutoConfig
        Write-LauncherLog 'PAC routing disabled (AutoConfigURL removed).' 'DarkGray'
    }
    if (Test-PacServerRunning) {
        Stop-PacServer
        Write-LauncherLog 'PAC server stopped.' 'DarkGray'
    }

    $warp = Get-WarpStatus -Force
    if ($warp.Installed -and $warp.Connected) {
        try { Disconnect-Warp; Write-LauncherLog 'WARP disconnected.' 'DarkGray' } catch { }
    }
}

# ============================================================================
# Connectivity smoke-test
# ============================================================================
function Test-Connectivity([hashtable]$cfg) {
    # Returns @{ Dpi=@{Ok;Detail}; Geo=@{Ok;Detail}; PacServer=@{Ok;Detail}; Warp=@{Ok;Detail} }
    $r = @{
        Dpi       = @{ Ok=$false; Detail='not tested' }
        Geo       = @{ Ok=$false; Detail='not tested' }
        PacServer = @{ Ok=$false; Detail='not tested' }
        Warp      = @{ Ok=$false; Detail='not tested' }
    }

    # PAC server reachable?
    if (Test-PacServerRunning) {
        $port = Get-PacPort $cfg
        try {
            $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$port/launcher.pac" -UseBasicParsing -TimeoutSec 3
            if ($resp.StatusCode -eq 200 -and $resp.Content -match 'FindProxyForURL') {
                $r.PacServer = @{ Ok=$true; Detail="serving on 127.0.0.1:$port ($([Math]::Round($resp.RawContentLength/1024,1)) KB)" }
            } else {
                $r.PacServer = @{ Ok=$false; Detail="bad response: $($resp.StatusCode)" }
            }
        } catch { $r.PacServer = @{ Ok=$false; Detail="$_" } }
    } else {
        $r.PacServer = @{ Ok=$false; Detail='PAC server is not running' }
    }

    # WARP proxy port (40000) reachable?
    $warpPing = $false
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $task = $tcp.ConnectAsync('127.0.0.1', 40000)
        if ($task.Wait(2000) -and $tcp.Connected) { $warpPing = $true }
        $tcp.Close()
    } catch { }
    if ($warpPing) {
        $r.Warp = @{ Ok=$true; Detail='SOCKS5 listener on 127.0.0.1:40000 is up' }
    } else {
        $r.Warp = @{ Ok=$false; Detail='no listener on 127.0.0.1:40000 (WARP proxy mode not running)' }
    }

    # DPI test — direct fetch to youtube. If zapret + winws is OK, this should
    # return 200/204 even on RU networks. We bypass any system proxy so the
    # PAC doesn't redirect this to WARP.
    try {
        $resp = Invoke-WebRequest -Uri 'https://www.youtube.com/generate_204' `
                    -UseBasicParsing -TimeoutSec 6 -Proxy $null -MaximumRedirection 0
        $code = $resp.StatusCode
        $r.Dpi = @{ Ok=($code -eq 204 -or $code -eq 200); Detail="HTTP $code from youtube.com (direct, zapret path)" }
    } catch {
        $r.Dpi = @{ Ok=$false; Detail="direct youtube.com failed: $($_.Exception.Message)" }
    }

    # Geo test — chatgpt.com via the WARP SOCKS5 proxy (if up).
    if ($warpPing) {
        try {
            $resp = Invoke-WebRequest -Uri 'https://chatgpt.com/' -UseBasicParsing -TimeoutSec 8 `
                        -Proxy 'http://127.0.0.1:40000' -MaximumRedirection 0
            $code = $resp.StatusCode
            $r.Geo = @{ Ok=($code -ge 200 -and $code -lt 500); Detail="HTTP $code from chatgpt.com (via WARP proxy)" }
        } catch {
            $msg = $_.Exception.Message
            # 403 / 451 still indicate we *reached* the server — counts as geo route working.
            if ($msg -match '\b(403|451)\b') {
                $r.Geo = @{ Ok=$false; Detail="chatgpt.com still blocks: $msg (WARP exit IP may be flagged)" }
            } else {
                $r.Geo = @{ Ok=$false; Detail="chatgpt.com via WARP failed: $msg" }
            }
        }
    } else {
        $r.Geo = @{ Ok=$false; Detail='skipped (WARP proxy not up)' }
    }

    return $r
}

# ============================================================================
# Misc tools
# ============================================================================
function Update-Lists {
    Write-LauncherLog 'Pulling latest lists from upstream (flowseal/zapret-discord-youtube main)...' 'Yellow'
    $base = 'https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/main/lists'
    $files = @('list-general.txt', 'list-google.txt', 'list-exclude.txt', 'ipset-exclude.txt', 'ipset-all.txt')
    foreach ($f in $files) {
        $dst = Join-Path $ListsDir $f
        try {
            Invoke-WebRequest -Uri "$base/$f" -OutFile $dst -UseBasicParsing -TimeoutSec 30
            Write-LauncherLog "  + $f" 'White'
        } catch {
            Write-LauncherLog "  ! $f ($_)" 'Red'
        }
    }
    Write-LauncherLog 'Done.' 'Green'
}

function Open-CustomDomains {
    $custom = Join-Path $ListsDir 'list-custom.txt'
    if (-not (Test-Path -LiteralPath $custom)) {
        Write-Utf8NoBom $custom @(
            '# Custom DPI domains — added to lists/list-general-user.txt on every Apply.',
            '# One domain per line. Lines starting with # are ignored.'
        )
    }
    Start-Process notepad.exe $custom
}

function Open-CustomGeoDomains {
    $f = Join-Path $ListsDir 'geo-custom.txt'
    if (-not (Test-Path -LiteralPath $f)) {
        Write-Utf8NoBom $f @(
            '# Custom geo-blocked domains — routed via Cloudflare WARP (when WARP is running).',
            '# One domain per line. Lines starting with # are ignored.'
        )
    }
    Start-Process notepad.exe $f
}

function Run-Diagnostics {
    $svc = Join-Path $RepoRoot 'service.bat'
    & cmd.exe /c "`"$svc`"" admin
}
