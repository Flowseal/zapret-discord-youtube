#Requires -Version 5.1
<#
.SYNOPSIS
  zapret-discord-youtube All-in-One Launcher.

.DESCRIPTION
  Single TUI to manage which sites zapret bypasses (Meta/X/LinkedIn/Signal/TikTok/News
  in addition to the built-in YouTube + Discord), to start/stop the bypass, to manage
  Cloudflare WARP, and to wire a user-supplied WireGuard tunnel or SOCKS5/HTTP proxy.

  Run via launcher.bat (which self-elevates).

.NOTES
  PowerShell 5.1 compatible. No third-party modules.
#>

$ErrorActionPreference = 'Stop'
$VerbosePreference     = 'SilentlyContinue'

# ============================================================================
# Paths
# ============================================================================
$Script:UtilsDir   = $PSScriptRoot
$Script:RepoRoot   = Split-Path -Parent $PSScriptRoot
$Script:ListsDir   = Join-Path $RepoRoot 'lists'
$Script:BinDir     = Join-Path $RepoRoot 'bin'
$Script:CustomDir  = Join-Path $RepoRoot 'custom-vpn'
$Script:ConfigPath = Join-Path $RepoRoot 'launcher.conf'
$Script:Version    = '1.0.0'

# ============================================================================
# Service catalogue
# ============================================================================
# Always-on lists are referenced directly by upstream general*.bat strategies
# and cannot be turned off without rewriting them. Toggleable lists are
# concatenated by the launcher into lists/list-general-user.txt, which every
# strategy already includes via --hostlist.
$Script:Services = [ordered]@{
    youtube   = @{ Name = 'YouTube';                            File = 'list-google.txt';   AlwaysOn = $true;  DefaultOn = $true  }
    discord   = @{ Name = 'Discord / Cloudflare / Twitch chat'; File = 'list-general.txt';  AlwaysOn = $true;  DefaultOn = $true  }
    meta      = @{ Name = 'Meta (Instagram/Facebook/Threads)';  File = 'list-meta.txt';     AlwaysOn = $false; DefaultOn = $true  }
    x         = @{ Name = 'X / Twitter';                        File = 'list-x.txt';        AlwaysOn = $false; DefaultOn = $true  }
    linkedin  = @{ Name = 'LinkedIn';                           File = 'list-linkedin.txt'; AlwaysOn = $false; DefaultOn = $true  }
    signal    = @{ Name = 'Signal';                             File = 'list-signal.txt';   AlwaysOn = $false; DefaultOn = $true  }
    tiktok    = @{ Name = 'TikTok';                             File = 'list-tiktok.txt';   AlwaysOn = $false; DefaultOn = $true  }
    news      = @{ Name = 'News (BBC/DW/Meduza/...)';           File = 'list-news.txt';     AlwaysOn = $false; DefaultOn = $false }
}

# ============================================================================
# Config persistence
# ============================================================================
function Get-DefaultConfig {
    $cfg = [ordered]@{}
    $cfg.strategy = 'general (FAKE TLS AUTO).bat'
    $cfg.warp_mode = 'warp+doh'
    foreach ($key in $Services.Keys) {
        $cfg["service_$key"] = if ($Services[$key].DefaultOn) { '1' } else { '0' }
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
# Helpers
# ============================================================================
function Pause-Key([string]$msg = 'Press Enter to continue...') {
    Write-Host ''
    Write-Host $msg -ForegroundColor DarkGray
    [void][Console]::ReadLine()
}

function Print-Header([string]$title) {
    Clear-Host
    Write-Host ''
    Write-Host "  $title" -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * ($title.Length + 4))) -ForegroundColor DarkGray
    Write-Host ''
}

function Print-Status([string]$label, [string]$value, [string]$color = 'White') {
    $padded = $label.PadRight(18)
    Write-Host "  $padded" -NoNewline
    Write-Host $value -ForegroundColor $color
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

function Read-MenuChoice([string]$prompt = 'Select option') {
    Write-Host ''
    Write-Host -NoNewline ("  $prompt`: ") -ForegroundColor Yellow
    [Console]::ReadLine()
}

# ============================================================================
# Service toggles -> rewrite list-general-user.txt
# ============================================================================
function Apply-Services([hashtable]$cfg) {
    $target = Join-Path $ListsDir 'list-general-user.txt'
    $domains = New-Object System.Collections.Generic.List[string]

    # Append enabled toggleable services (skip always-on; they're in their own files)
    foreach ($key in $Services.Keys) {
        $svc = $Services[$key]
        if ($svc.AlwaysOn) { continue }
        if ($cfg["service_$key"] -ne '1') { continue }
        $path = Join-Path $ListsDir $svc.File
        if (Test-Path $path) {
            foreach ($line in Get-Content -LiteralPath $path -Encoding UTF8) {
                $t = $line.Trim()
                if ($t -and -not $t.StartsWith('#')) { $null = $domains.Add($t) }
            }
        }
    }

    # Honour user-supplied custom list (lists/list-custom.txt) if present.
    $custom = Join-Path $ListsDir 'list-custom.txt'
    if (Test-Path $custom) {
        foreach ($line in Get-Content -LiteralPath $custom -Encoding UTF8) {
            $t = $line.Trim()
            if ($t -and -not $t.StartsWith('#')) { $null = $domains.Add($t) }
        }
    }

    if ($domains.Count -eq 0) {
        # winws.exe rejects empty hostlists; keep the upstream placeholder.
        Write-Utf8NoBom $target @('domain.example.abc')
    } else {
        $unique = @($domains | Sort-Object -Unique)
        Write-Utf8NoBom $target $unique
    }
}

# ============================================================================
# Bypass control
# ============================================================================
function Get-StrategyFiles {
    Get-ChildItem -LiteralPath $RepoRoot -Filter '*.bat' |
        Where-Object { $_.Name -notlike 'service*' -and $_.Name -ne 'launcher.bat' } |
        Sort-Object {
            [Regex]::Replace($_.Name, '(\d+)', { param($m) $m.Value.PadLeft(8, '0') })
        } |
        Select-Object -ExpandProperty Name
}

function Stop-Bypass {
    if (Test-WinwsRunning) {
        Get-Process -Name 'winws' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
    }
}

function Start-Bypass([hashtable]$cfg) {
    if (Test-ServiceRunning 'zapret') {
        Write-Host '  zapret service is RUNNING. Remove the service first or use service.bat.' -ForegroundColor Red
        return
    }

    Stop-Bypass
    Apply-Services $cfg

    $batPath = Join-Path $RepoRoot $cfg.strategy
    if (-not (Test-Path -LiteralPath $batPath)) {
        Write-Host "  Strategy file not found: $($cfg.strategy)" -ForegroundColor Red
        return
    }

    Write-Host "  Starting strategy: $($cfg.strategy)" -ForegroundColor Green
    # Hand off to upstream .bat — it sets %BIN%/%LISTS%, calls service.bat hooks,
    # and runs winws.exe with the right desync flags. The .bat itself uses
    # `start "" /min winws.exe ...`, so it returns immediately.
    & cmd.exe /c "call `"$batPath`""
    Start-Sleep -Seconds 2
    if (Test-WinwsRunning) {
        Write-Host '  Bypass started.' -ForegroundColor Green
    } else {
        Write-Host '  winws.exe did not start. Check the strategy file or run service.bat -> Run Diagnostics.' -ForegroundColor Red
    }
}

# ============================================================================
# Menus: services
# ============================================================================
function Show-ServicesMenu([hashtable]$cfg) {
    while ($true) {
        Print-Header 'TOGGLE SERVICES'
        Write-Host '  Always-on (built into upstream strategies):' -ForegroundColor DarkGray
        $idx = 1
        $indexMap = @{}
        foreach ($key in $Services.Keys) {
            $svc = $Services[$key]
            if ($svc.AlwaysOn) {
                Write-Host ('     *  {0}' -f $svc.Name) -ForegroundColor DarkGray
            }
        }
        Write-Host ''
        Write-Host '  Toggleable (managed via list-general-user.txt):'
        foreach ($key in $Services.Keys) {
            $svc = $Services[$key]
            if ($svc.AlwaysOn) { continue }
            $on = $cfg["service_$key"] -eq '1'
            $tag = if ($on) { '[ON ]' } else { '[OFF]' }
            $col = if ($on) { 'Green' } else { 'DarkGray' }
            Write-Host ('   {0,2}. ' -f $idx) -NoNewline
            Write-Host $tag -NoNewline -ForegroundColor $col
            Write-Host (' ' + $svc.Name)
            $indexMap[$idx] = $key
            $idx++
        }
        Write-Host ''
        Write-Host '    A. Enable all toggleable'
        Write-Host '    N. Disable all toggleable'
        Write-Host '    0. Back'

        $c = (Read-MenuChoice).Trim().ToUpper()
        if ($c -eq '0' -or $c -eq '') { return }
        if ($c -eq 'A') {
            foreach ($k in $indexMap.Values) { $cfg["service_$k"] = '1' }
            Save-Config $cfg
            continue
        }
        if ($c -eq 'N') {
            foreach ($k in $indexMap.Values) { $cfg["service_$k"] = '0' }
            Save-Config $cfg
            continue
        }
        $n = 0
        if ([int]::TryParse($c, [ref]$n) -and $indexMap.ContainsKey($n)) {
            $key = $indexMap[$n]
            $cur = $cfg["service_$key"] -eq '1'
            $cfg["service_$key"] = if ($cur) { '0' } else { '1' }
            Save-Config $cfg
        }
    }
}

# ============================================================================
# Menus: strategy
# ============================================================================
function Show-StrategyMenu([hashtable]$cfg) {
    while ($true) {
        Print-Header 'PICK STRATEGY'
        Write-Host '  Different DPI providers respond to different desync techniques.'
        Write-Host '  If the current strategy stops working, try ALT / FAKE TLS AUTO / SIMPLE FAKE variants.' -ForegroundColor DarkGray
        Write-Host ''

        $files = @(Get-StrategyFiles)
        $idx = 1
        foreach ($f in $files) {
            $marker = if ($f -eq $cfg.strategy) { '*' } else { ' ' }
            $col = if ($f -eq $cfg.strategy) { 'Green' } else { 'White' }
            Write-Host ('   {0,2}. {1} {2}' -f $idx, $marker, $f) -ForegroundColor $col
            $idx++
        }
        Write-Host ''
        Write-Host '    0. Back'

        $c = (Read-MenuChoice).Trim()
        if ($c -eq '0' -or $c -eq '') { return }
        $n = 0
        if ([int]::TryParse($c, [ref]$n) -and $n -ge 1 -and $n -le $files.Count) {
            $cfg.strategy = $files[$n - 1]
            Save-Config $cfg
            return
        }
    }
}

# ============================================================================
# Menus: Cloudflare WARP
# ============================================================================
function Get-WarpCli {
    foreach ($p in @(
        (Join-Path ${env:ProgramFiles} 'Cloudflare\Cloudflare WARP\warp-cli.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Cloudflare\Cloudflare WARP\warp-cli.exe'),
        'warp-cli.exe'
    )) {
        if ($p -and (Test-Path $p)) { return $p }
    }
    $cmd = Get-Command 'warp-cli.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Invoke-WarpCli {
    param([Parameter(ValueFromRemainingArguments=$true)] [string[]]$ArgList)
    $exe = Get-WarpCli
    if (-not $exe) { throw 'warp-cli not found.' }
    & $exe @ArgList
}

function Get-WarpStatus {
    $exe = Get-WarpCli
    if (-not $exe) { return @{ Installed = $false } }
    $out = ''
    try { $out = (& $exe 'status' 2>&1) -join "`n" } catch { $out = "$_" }
    # warp-cli output across versions: "Status update: Connected", "Status: Connected".
    $connected = ($out -match '(?im)^\s*Status(?:\s+update)?\s*:\s*(Connected|Connecting)\b')
    @{ Installed = $true; Connected = $connected; Raw = $out }
}

function Install-Warp {
    Write-Host '  Installing Cloudflare WARP via winget...' -ForegroundColor Yellow
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        Write-Host '  winget is not available on this system.' -ForegroundColor Red
        Write-Host '  Download manually from https://1.1.1.1/' -ForegroundColor Yellow
        return
    }
    $wingetArgs = @(
        'install', '--id', 'Cloudflare.Warp', '-e',
        '--accept-package-agreements', '--accept-source-agreements'
    )
    & winget @wingetArgs
    Write-Host ''
    if (Get-WarpCli) {
        Write-Host '  WARP installed. Registering client (accepts ToS)...' -ForegroundColor Green
        try { Invoke-WarpCli 'registration' 'new' 2>&1 | Out-Null } catch {}
        try { Invoke-WarpCli 'register' 2>&1 | Out-Null } catch {}
    } else {
        Write-Host '  Install finished but warp-cli was not detected.' -ForegroundColor Yellow
    }
}

function Show-WarpMenu([hashtable]$cfg) {
    while ($true) {
        Print-Header 'CLOUDFLARE WARP'
        $st = Get-WarpStatus
        if (-not $st.Installed) {
            Print-Status 'Status:'  'NOT INSTALLED' 'Red'
        } elseif ($st.Connected) {
            Print-Status 'Status:'  'CONNECTED' 'Green'
        } else {
            Print-Status 'Status:'  'disconnected' 'DarkGray'
        }
        Print-Status 'Saved mode:' $cfg.warp_mode 'White'
        Write-Host ''
        Write-Host '  WARP is free, no signup, run by Cloudflare. It gives you a different exit IP'
        Write-Host '  (helps with some geo-blocks). It is NOT a substitute for zapret against RU DPI.' -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '   1. Install (winget Cloudflare.Warp)'
        Write-Host '   2. Connect'
        Write-Host '   3. Disconnect'
        Write-Host '   4. Mode -> warp        (full tunnel, default)'
        Write-Host '   5. Mode -> warp+doh    (tunnel + DNS-over-HTTPS)'
        Write-Host '   6. Mode -> doh         (DNS-only, no tunnel)'
        Write-Host '   7. Mode -> proxy       (local SOCKS proxy on 127.0.0.1:40000)'
        Write-Host '   8. Show full status'
        Write-Host ''
        Write-Host '   0. Back'

        $c = (Read-MenuChoice).Trim()
        switch ($c) {
            '0' { return }
            ''  { return }
            '1' { Install-Warp; Pause-Key }
            '2' {
                try { Invoke-WarpCli 'connect' } catch { Write-Host "  $_" -ForegroundColor Red }
                Pause-Key
            }
            '3' {
                try { Invoke-WarpCli 'disconnect' } catch { Write-Host "  $_" -ForegroundColor Red }
                Pause-Key
            }
            { $_ -in @('4','5','6','7') } {
                $modeMap = @{ '4' = 'warp'; '5' = 'warp+doh'; '6' = 'doh'; '7' = 'proxy' }
                $mode = $modeMap[$c]
                try {
                    Invoke-WarpCli 'mode' $mode
                    $cfg.warp_mode = $mode
                    Save-Config $cfg
                    Write-Host "  Mode set to $mode." -ForegroundColor Green
                } catch { Write-Host "  $_" -ForegroundColor Red }
                Pause-Key
            }
            '8' {
                $st = Get-WarpStatus
                Write-Host ''
                if ($st.Installed) { Write-Host $st.Raw } else { Write-Host '  WARP is not installed.' -ForegroundColor Red }
                Pause-Key
            }
            default { }
        }
    }
}

# ============================================================================
# Menus: Custom VPN / Proxy
# ============================================================================
function Get-WireGuardExe {
    foreach ($p in @(
        (Join-Path ${env:ProgramFiles} 'WireGuard\wireguard.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'WireGuard\wireguard.exe')
    )) {
        if ($p -and (Test-Path $p)) { return $p }
    }
    return $null
}

function Import-WireGuardConf {
    if (-not (Test-Path $CustomDir)) { $null = New-Item -ItemType Directory -Path $CustomDir }
    Write-Host '  Drop your WireGuard config (.conf) into:' -ForegroundColor Yellow
    Write-Host "    $CustomDir" -ForegroundColor White
    Write-Host '  ...or paste a full path here.' -ForegroundColor DarkGray
    Write-Host -NoNewline '  Path to .conf (Enter for default folder pick): ' -ForegroundColor Yellow
    $p = [Console]::ReadLine().Trim('"').Trim()

    if (-not $p) {
        $candidates = @(Get-ChildItem -LiteralPath $CustomDir -Filter '*.conf' -ErrorAction SilentlyContinue)
        if (-not $candidates) {
            Write-Host "  No .conf files in $CustomDir" -ForegroundColor Red
            return
        }
        if ($candidates.Count -eq 1) {
            $p = $candidates[0].FullName
        } else {
            for ($i=0; $i -lt $candidates.Count; $i++) {
                Write-Host ('   {0}. {1}' -f ($i+1), $candidates[$i].Name)
            }
            Write-Host -NoNewline '  Pick (number): ' -ForegroundColor Yellow
            $n = 0
            if (-not [int]::TryParse([Console]::ReadLine(), [ref]$n)) { return }
            if ($n -lt 1 -or $n -gt $candidates.Count) { return }
            $p = $candidates[$n-1].FullName
        }
    }

    if (-not (Test-Path -LiteralPath $p)) {
        Write-Host "  File not found: $p" -ForegroundColor Red
        return
    }

    $wg = Get-WireGuardExe
    if (-not $wg) {
        Write-Host '  WireGuard for Windows is not installed.' -ForegroundColor Red
        Write-Host '  Install: winget install -e --id WireGuard.WireGuard' -ForegroundColor Yellow
        Write-Host '  Or download from https://www.wireguard.com/install/' -ForegroundColor Yellow
        return
    }

    Write-Host "  Installing tunnel from $p ..." -ForegroundColor Yellow
    & $wg /installtunnelservice $p
    Write-Host '  If WireGuard prompted for confirmation, accept it. Tunnel should be up.' -ForegroundColor Green
}

function Stop-WireGuardTunnels {
    $tunnels = @(Get-Service | Where-Object { $_.Name -like 'WireGuardTunnel$*' })
    if (-not $tunnels) {
        Write-Host '  No WireGuard tunnel services found.' -ForegroundColor DarkGray
        return
    }
    foreach ($t in $tunnels) {
        $name = $t.Name
        Write-Host "  Stopping $name ..."
        & sc.exe stop $name | Out-Null
        & sc.exe delete $name | Out-Null
    }
    Write-Host '  All WireGuard tunnels stopped.' -ForegroundColor Green
}

function Set-SystemProxy {
    Write-Host '  Examples: socks=127.0.0.1:1080  |  http=proxy.example.com:8080  |  myproxy.example.com:3128' -ForegroundColor DarkGray
    Write-Host -NoNewline '  Proxy (host:port or proto=host:port): ' -ForegroundColor Yellow
    $p = [Console]::ReadLine().Trim()
    if (-not $p) { return }

    $regKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    Set-ItemProperty -Path $regKey -Name ProxyServer -Value $p
    Set-ItemProperty -Path $regKey -Name ProxyEnable -Value 1 -Type DWord
    Set-ItemProperty -Path $regKey -Name ProxyOverride -Value '<local>'

    # Also set WinHTTP-level proxy (covers some background services, requires admin).
    & netsh winhttp set proxy proxy-server="$p" bypass-list="<local>" | Out-Null

    Write-Host "  System proxy set: $p" -ForegroundColor Green
    Write-Host '  Note: most browsers respect this. QUIC/HTTP3 traffic does NOT go through HTTP proxy.' -ForegroundColor DarkGray
}

function Disable-SystemProxy {
    $regKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    Set-ItemProperty -Path $regKey -Name ProxyEnable -Value 0 -Type DWord
    & netsh winhttp reset proxy | Out-Null
    Write-Host '  System proxy disabled.' -ForegroundColor Green
}

function Show-CustomVpnMenu([hashtable]$cfg) {
    while ($true) {
        Print-Header 'CUSTOM VPN / PROXY'
        Write-Host '  This is for YOUR OWN trusted VPN/proxy (your VPS, paid VPN, etc.)' -ForegroundColor White
        Write-Host '  We deliberately do NOT ship random public proxies — they are honeypots.' -ForegroundColor DarkGray
        Write-Host ''

        $wg = Get-WireGuardExe
        if ($wg) { Print-Status 'WireGuard:' 'installed' 'Green' }
        else     { Print-Status 'WireGuard:' 'NOT installed' 'DarkGray' }

        $tunnels = @(Get-Service | Where-Object { $_.Name -like 'WireGuardTunnel$*' -and $_.Status -eq 'Running' })
        if ($tunnels) { Print-Status 'Active tunnel:' ($tunnels.Name -join ', ') 'Green' }

        $regKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
        $proxyEnabled = (Get-ItemProperty -Path $regKey -Name ProxyEnable -ErrorAction SilentlyContinue).ProxyEnable
        if ($proxyEnabled -eq 1) {
            $proxy = (Get-ItemProperty -Path $regKey -Name ProxyServer -ErrorAction SilentlyContinue).ProxyServer
            Print-Status 'System proxy:' "ON ($proxy)" 'Green'
        } else {
            Print-Status 'System proxy:' 'off' 'DarkGray'
        }

        Write-Host ''
        Write-Host '   1. Import WireGuard .conf and start as Windows service'
        Write-Host '   2. Stop / remove all WireGuard tunnels'
        Write-Host '   3. Install WireGuard for Windows (winget)'
        Write-Host '   4. Set system SOCKS5 / HTTP proxy'
        Write-Host '   5. Disable system proxy'
        Write-Host '   6. Open custom-vpn folder'
        Write-Host ''
        Write-Host '   0. Back'

        $c = (Read-MenuChoice).Trim()
        switch ($c) {
            '0' { return }
            ''  { return }
            '1' { Import-WireGuardConf; Pause-Key }
            '2' { Stop-WireGuardTunnels; Pause-Key }
            '3' {
                $winget = Get-Command winget -ErrorAction SilentlyContinue
                if ($winget) { & winget install -e --id WireGuard.WireGuard --accept-package-agreements --accept-source-agreements }
                else { Write-Host '  winget not available — get installer from https://www.wireguard.com/install/' -ForegroundColor Yellow }
                Pause-Key
            }
            '4' { Set-SystemProxy; Pause-Key }
            '5' { Disable-SystemProxy; Pause-Key }
            '6' {
                if (-not (Test-Path $CustomDir)) { $null = New-Item -ItemType Directory -Path $CustomDir }
                Start-Process explorer.exe $CustomDir
            }
            default { }
        }
    }
}

# ============================================================================
# Menus: tools
# ============================================================================
function Edit-CustomDomains {
    $custom = Join-Path $ListsDir 'list-custom.txt'
    if (-not (Test-Path -LiteralPath $custom)) {
        Set-Content -LiteralPath $custom -Value @(
            '# Add one domain per line. These are unioned with the toggled service lists',
            '# every time you press "Start bypass" / "Apply".',
            '# Lines starting with # are ignored.'
        ) -Encoding UTF8
    }
    Start-Process notepad.exe $custom
    Write-Host '  Opened in Notepad. Save and close, then re-apply / restart the bypass.' -ForegroundColor DarkGray
    Pause-Key
}

function Update-Lists {
    Write-Host '  Pulling latest lists from upstream (flowseal/zapret-discord-youtube main)...' -ForegroundColor Yellow
    $base = 'https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/main/lists'
    $files = @('list-general.txt', 'list-google.txt', 'list-exclude.txt', 'ipset-exclude.txt', 'ipset-all.txt')
    foreach ($f in $files) {
        $dst = Join-Path $ListsDir $f
        try {
            Invoke-WebRequest -Uri "$base/$f" -OutFile $dst -UseBasicParsing -TimeoutSec 30
            Write-Host "    + $f"
        } catch {
            Write-Host "    ! $f ($_)" -ForegroundColor Red
        }
    }
    Write-Host '  Done.' -ForegroundColor Green
    Pause-Key
}

function Run-Diagnostics {
    $svc = Join-Path $RepoRoot 'service.bat'
    Write-Host '  Handing off to service.bat (the upstream menu has Run Diagnostics).' -ForegroundColor DarkGray
    & cmd.exe /c "`"$svc`"" admin
}

# ============================================================================
# Main menu
# ============================================================================
function Show-MainMenu {
    $cfg = Read-Config
    Apply-Services $cfg  # refresh list-general-user.txt on startup

    while ($true) {
        Print-Header "ZAPRET ALL-IN-ONE LAUNCHER v$Version"

        $enabledNames = @()
        foreach ($key in $Services.Keys) {
            $svc = $Services[$key]
            if ($svc.AlwaysOn) { $enabledNames += $svc.Name; continue }
            if ($cfg["service_$key"] -eq '1') { $enabledNames += $svc.Name }
        }

        $bypass = if (Test-WinwsRunning) { 'RUNNING' } else { 'stopped' }
        $bypassColor = if ($bypass -eq 'RUNNING') { 'Green' } else { 'DarkGray' }
        $svcInstalled = Test-ServiceInstalled 'zapret'
        $svcRunning = Test-ServiceRunning 'zapret'

        $warpStatus = Get-WarpStatus
        $warpStr = if (-not $warpStatus.Installed) { 'not installed' }
                   elseif ($warpStatus.Connected) { 'CONNECTED' }
                   else { 'installed, off' }
        $warpCol = if ($warpStatus.Connected) { 'Green' } elseif ($warpStatus.Installed) { 'DarkGray' } else { 'DarkGray' }

        Print-Status 'Active services:' (($enabledNames -join ', ')) 'White'
        Print-Status 'Strategy:'        $cfg.strategy 'White'
        Print-Status 'Bypass:'          $bypass $bypassColor
        $svcLine = if (-not $svcInstalled) { 'not installed' } elseif ($svcRunning) { 'running' } else { 'installed, stopped' }
        Print-Status 'Win service:'     $svcLine ($(if ($svcRunning) { 'Green' } else { 'DarkGray' }))
        Print-Status 'WARP:'            $warpStr $warpCol

        Write-Host ''
        Write-Host '  :: BYPASS' -ForegroundColor Magenta
        Write-Host '     1. Toggle services'
        Write-Host '     2. Pick strategy'
        Write-Host '     3. Start bypass (apply services + run strategy)'
        Write-Host '     4. Stop bypass'
        Write-Host ''
        Write-Host '  :: AUTOSTART' -ForegroundColor Magenta
        Write-Host '     5. Open service.bat (install/remove Windows service, advanced)'
        Write-Host ''
        Write-Host '  :: ADDITIONAL ROUTING' -ForegroundColor Magenta
        Write-Host '     6. Cloudflare WARP'
        Write-Host '     7. Custom VPN / Proxy (your own)'
        Write-Host ''
        Write-Host '  :: TOOLS' -ForegroundColor Magenta
        Write-Host '     8. Edit custom domain list'
        Write-Host '     9. Update domain lists from upstream'
        Write-Host '    10. Run diagnostics (via service.bat)'
        Write-Host ''
        Write-Host '     0. Exit'

        $c = (Read-MenuChoice).Trim()
        switch ($c) {
            '0' { return }
            ''  { }
            '1' { Show-ServicesMenu $cfg; Apply-Services $cfg }
            '2' { Show-StrategyMenu $cfg }
            '3' { Start-Bypass $cfg; Pause-Key }
            '4' { Stop-Bypass; Write-Host '  Bypass stopped.' -ForegroundColor Yellow; Pause-Key }
            '5' { Run-Diagnostics }
            '6' { Show-WarpMenu $cfg }
            '7' { Show-CustomVpnMenu $cfg }
            '8' { Edit-CustomDomains }
            '9' { Update-Lists }
            '10' { Run-Diagnostics }
            default { }
        }
    }
}

# ============================================================================
# Entry point
# ============================================================================
try {
    if (-not (Test-Path $ListsDir))  { throw "lists/ dir not found at $ListsDir" }
    if (-not (Test-Path $BinDir))    { throw "bin/ dir not found at $BinDir" }
    Show-MainMenu
} catch {
    Write-Host ''
    Write-Host "  FATAL: $_" -ForegroundColor Red
    Write-Host ''
    Pause-Key 'Press Enter to exit...'
    exit 1
}
