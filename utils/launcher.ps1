#Requires -Version 5.1
<#
.SYNOPSIS
  codeDPI All-in-One Launcher (CLI / TUI).

.DESCRIPTION
  Console menu for managing DPI services, strategy, WARP, custom VPN, and the
  PAC-based geo-routing layer. The default entry point is launcher.bat which
  now opens the WPF GUI (utils/launcher.gui.ps1); pass `launcher.bat cli` to
  use this console version.
#>

. (Join-Path $PSScriptRoot 'launcher.lib.ps1')

$ErrorActionPreference = 'Stop'
$VerbosePreference     = 'SilentlyContinue'

# ============================================================================
# Console-only helpers
# ============================================================================
$Script:LogSink = {
    param([string]$msg, [string]$color)
    if (-not $color) { $color = 'White' }
    Write-Host "  $msg" -ForegroundColor $color
}

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

function Read-MenuChoice([string]$prompt = 'Select option') {
    Write-Host ''
    Write-Host -NoNewline ("  $prompt`: ") -ForegroundColor Yellow
    [Console]::ReadLine()
}

# ============================================================================
# Menus: services
# ============================================================================
function Show-ServicesMenu([hashtable]$cfg) {
    while ($true) {
        Print-Header 'TOGGLE DPI SERVICES'
        Write-Host '  Always-on (built into upstream strategies):' -ForegroundColor DarkGray
        foreach ($key in $Services.Keys) {
            if ($Services[$key].AlwaysOn) {
                Write-Host ('     *  {0}' -f $Services[$key].Name) -ForegroundColor DarkGray
            }
        }
        Write-Host ''
        Write-Host '  Toggleable (managed via list-general-user.txt):'
        $idx = 1
        $indexMap = @{}
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
        if ($c -eq 'A') { foreach ($k in $indexMap.Values) { $cfg["service_$k"] = '1' }; Save-Config $cfg; continue }
        if ($c -eq 'N') { foreach ($k in $indexMap.Values) { $cfg["service_$k"] = '0' }; Save-Config $cfg; continue }
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
# Menus: geo services
# ============================================================================
function Show-GeoMenu([hashtable]$cfg) {
    while ($true) {
        Print-Header 'GEO-BLOCKED SERVICES (routed via WARP / PAC)'
        Write-Host '  These domains zapret CANNOT unblock — they refuse RU IPs server-side.' -ForegroundColor DarkGray
        Write-Host '  Selected ones go through WARP via a generated PAC file.' -ForegroundColor DarkGray
        Write-Host ''
        $idx = 1
        $indexMap = @{}
        foreach ($key in $GeoServices.Keys) {
            $on = $cfg["geo_$key"] -eq '1'
            $tag = if ($on) { '[ON ]' } else { '[OFF]' }
            $col = if ($on) { 'Green' } else { 'DarkGray' }
            Write-Host ('   {0,2}. ' -f $idx) -NoNewline
            Write-Host $tag -NoNewline -ForegroundColor $col
            Write-Host (' ' + $GeoServices[$key].Name)
            $indexMap[$idx] = $key
            $idx++
        }
        Write-Host ''
        Write-Host '    P. Rebuild PAC file now'
        Write-Host '    U. Show PAC URL (paste into Firefox)'
        Write-Host '    E. Edit custom geo list'
        Write-Host '    0. Back'
        $c = (Read-MenuChoice).Trim().ToUpper()
        if ($c -eq '0' -or $c -eq '') { return }
        if ($c -eq 'P') {
            $info = Write-PacFile $cfg
            Write-Host "  PAC rebuilt: $($info.DomainCount) domains" -ForegroundColor Green
            Pause-Key
            continue
        }
        if ($c -eq 'U') {
            Write-Host ('  ' + (Get-PacFileUrl $cfg)) -ForegroundColor Cyan
            Pause-Key
            continue
        }
        if ($c -eq 'E') { Open-CustomGeoDomains; Pause-Key; continue }
        $n = 0
        if ([int]::TryParse($c, [ref]$n) -and $indexMap.ContainsKey($n)) {
            $key = $indexMap[$n]
            $cur = $cfg["geo_$key"] -eq '1'
            $cfg["geo_$key"] = if ($cur) { '0' } else { '1' }
            Save-Config $cfg
            if (Test-PacEnabled $cfg) { Write-PacFile $cfg | Out-Null }
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
            $col    = if ($f -eq $cfg.strategy) { 'Green' } else { 'White' }
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
# Menus: WARP
# ============================================================================
function Show-WarpMenu([hashtable]$cfg) {
    while ($true) {
        Print-Header 'CLOUDFLARE WARP'
        $st = Get-WarpStatus
        if (-not $st.Installed)        { Print-Status 'Status:'  'NOT INSTALLED' 'Red' }
        elseif ($st.Connected)         { Print-Status 'Status:'  'CONNECTED' 'Green' }
        else                           { Print-Status 'Status:'  'disconnected' 'DarkGray' }
        Print-Status 'Saved mode:' $cfg.warp_mode 'White'
        Print-Status 'Auto-start:'  $(if ($cfg.warp_autostart -eq '1') { 'ON' } else { 'OFF' }) $(if ($cfg.warp_autostart -eq '1') { 'Green' } else { 'DarkGray' })
        Print-Status 'PAC routing:' $(if ($cfg.geo_routing    -eq '1') { 'ON' } else { 'OFF' }) $(if ($cfg.geo_routing    -eq '1') { 'Green' } else { 'DarkGray' })
        Write-Host ''
        Write-Host '   1. Install (winget Cloudflare.Warp)'
        Write-Host '   2. Connect'
        Write-Host '   3. Disconnect'
        Write-Host '   4. Mode -> warp        (full tunnel, default)'
        Write-Host '   5. Mode -> warp+doh    (tunnel + DNS-over-HTTPS)'
        Write-Host '   6. Mode -> doh         (DNS-only, no tunnel)'
        Write-Host '   7. Mode -> proxy       (local SOCKS5 proxy on 127.0.0.1:40000)'
        Write-Host '   8. Toggle auto-start with bypass'
        Write-Host '   9. Toggle PAC routing for geo services'
        Write-Host '  10. Show full status'
        Write-Host ''
        Write-Host '   0. Back'
        $c = (Read-MenuChoice).Trim()
        switch ($c) {
            '0' { return } '' { return }
            '1' { Install-Warp | Out-Null; Pause-Key }
            '2' { try { Connect-Warp } catch { Write-Host "  $_" -ForegroundColor Red }; Pause-Key }
            '3' { try { Disconnect-Warp } catch { Write-Host "  $_" -ForegroundColor Red }; Pause-Key }
            { $_ -in @('4','5','6','7') } {
                $modeMap = @{ '4'='warp'; '5'='warp+doh'; '6'='doh'; '7'='proxy' }
                try {
                    Set-WarpMode $modeMap[$c]
                    $cfg.warp_mode = $modeMap[$c]
                    Save-Config $cfg
                    Write-Host "  Mode set to $($modeMap[$c])." -ForegroundColor Green
                } catch { Write-Host "  $_" -ForegroundColor Red }
                Pause-Key
            }
            '8' {
                $cfg.warp_autostart = if ($cfg.warp_autostart -eq '1') { '0' } else { '1' }
                Save-Config $cfg
            }
            '9' {
                $cfg.geo_routing = if ($cfg.geo_routing -eq '1') { '0' } else { '1' }
                Save-Config $cfg
            }
            '10' {
                $st = Get-WarpStatus
                Write-Host ''
                if ($st.Installed) { Write-Host $st.Raw } else { Write-Host '  WARP is not installed.' -ForegroundColor Red }
                Pause-Key
            }
        }
    }
}

# ============================================================================
# Menus: Custom VPN
# ============================================================================
function Show-CustomVpnMenu([hashtable]$cfg) {
    while ($true) {
        Print-Header 'CUSTOM VPN / PROXY'
        Write-Host '  This is for YOUR OWN trusted VPN/proxy (your VPS, paid VPN, etc.)' -ForegroundColor White
        Write-Host '  We deliberately do NOT ship random public proxies — they are honeypots.' -ForegroundColor DarkGray
        Write-Host ''
        $wg = Get-WireGuardExe
        if ($wg) { Print-Status 'WireGuard:' 'installed' 'Green' }
        else     { Print-Status 'WireGuard:' 'NOT installed' 'DarkGray' }
        $tunnels = Get-WireGuardTunnels | Where-Object { $_.Status -eq 'Running' }
        if ($tunnels) { Print-Status 'Active tunnel:' ($tunnels.Name -join ', ') 'Green' }
        $proxy = Get-SystemProxyStatus
        if ($proxy.Enabled)        { Print-Status 'System proxy:' "ON ($($proxy.Server))" 'Green' }
        else                       { Print-Status 'System proxy:' 'off' 'DarkGray' }
        if ($proxy.AutoConfigURL)  { Print-Status 'AutoConfigURL:' $proxy.AutoConfigURL 'Cyan' }
        Write-Host ''
        Write-Host '   1. Import WireGuard .conf and start as Windows service'
        Write-Host '   2. Stop / remove all WireGuard tunnels'
        Write-Host '   3. Install WireGuard for Windows (winget)'
        Write-Host '   4. Set system SOCKS5 / HTTP proxy'
        Write-Host '   5. Disable system proxy (preserves AutoConfigURL)'
        Write-Host '   6. Open custom-vpn folder'
        Write-Host ''
        Write-Host '   0. Back'
        $c = (Read-MenuChoice).Trim()
        switch ($c) {
            '0' { return } '' { return }
            '1' {
                if (-not (Test-Path $CustomDir)) { $null = New-Item -ItemType Directory -Path $CustomDir }
                $candidates = @(Get-ChildItem -LiteralPath $CustomDir -Filter '*.conf' -ErrorAction SilentlyContinue)
                if (-not $candidates) {
                    Write-Host "  No .conf files in $CustomDir — drop one there first." -ForegroundColor Yellow
                } elseif ($candidates.Count -eq 1) {
                    try { Install-WireGuardTunnel $candidates[0].FullName; Write-Host '  Tunnel installed.' -ForegroundColor Green } catch { Write-Host "  $_" -ForegroundColor Red }
                } else {
                    for ($i=0; $i -lt $candidates.Count; $i++) {
                        Write-Host ('   {0}. {1}' -f ($i+1), $candidates[$i].Name)
                    }
                    Write-Host -NoNewline '  Pick (number): ' -ForegroundColor Yellow
                    $n = 0
                    if ([int]::TryParse([Console]::ReadLine(), [ref]$n) -and $n -ge 1 -and $n -le $candidates.Count) {
                        try { Install-WireGuardTunnel $candidates[$n-1].FullName; Write-Host '  Tunnel installed.' -ForegroundColor Green } catch { Write-Host "  $_" -ForegroundColor Red }
                    }
                }
                Pause-Key
            }
            '2' {
                $n = Stop-WireGuardTunnels
                Write-Host "  Stopped $n tunnel(s)." -ForegroundColor $(if ($n -gt 0) { 'Green' } else { 'DarkGray' })
                Pause-Key
            }
            '3' { Install-WireGuard | Out-Null; Pause-Key }
            '4' {
                Write-Host '  Examples: socks=127.0.0.1:1080  |  http=proxy.example.com:8080  |  myproxy.example.com:3128' -ForegroundColor DarkGray
                Write-Host -NoNewline '  Proxy: ' -ForegroundColor Yellow
                $p = [Console]::ReadLine().Trim()
                if ($p) {
                    try { Set-SystemProxy $p; Write-Host "  Set: $p" -ForegroundColor Green } catch { Write-Host "  $_" -ForegroundColor Red }
                }
                Pause-Key
            }
            '5' { Disable-SystemProxy; Write-Host '  System proxy disabled.' -ForegroundColor Green; Pause-Key }
            '6' {
                if (-not (Test-Path $CustomDir)) { $null = New-Item -ItemType Directory -Path $CustomDir }
                Start-Process explorer.exe $CustomDir
            }
        }
    }
}

# ============================================================================
# Main menu
# ============================================================================
function Show-MainMenu {
    $cfg = Read-Config
    Apply-Services $cfg

    while ($true) {
        Print-Header "CODEDPI LAUNCHER v$Version"

        $enabledNames = @()
        foreach ($key in $Services.Keys) {
            $svc = $Services[$key]
            if ($svc.AlwaysOn) { $enabledNames += $svc.Name; continue }
            if ($cfg["service_$key"] -eq '1') { $enabledNames += $svc.Name }
        }
        $geoNames = @()
        foreach ($key in $GeoServices.Keys) {
            if ($cfg["geo_$key"] -eq '1') { $geoNames += $GeoServices[$key].Name }
        }

        $bypass = if (Test-WinwsRunning) { 'RUNNING' } else { 'stopped' }
        $bypassColor = if ($bypass -eq 'RUNNING') { 'Green' } else { 'DarkGray' }
        $svcInstalled = Test-ServiceInstalled 'zapret'
        $svcRunning   = Test-ServiceRunning 'zapret'
        $warp = Get-WarpStatus
        $warpStr = if (-not $warp.Installed) { 'not installed' } elseif ($warp.Connected) { 'CONNECTED' } else { 'installed, off' }
        $warpCol = if ($warp.Connected) { 'Green' } else { 'DarkGray' }
        $pac = Test-PacEnabled $cfg

        Print-Status 'DPI services:'   (($enabledNames -join ', ')) 'White'
        Print-Status 'Geo services:'   ($(if ($geoNames) { $geoNames -join ', ' } else { '(none)' })) 'White'
        Print-Status 'Strategy:'       $cfg.strategy 'White'
        Print-Status 'Bypass:'         $bypass $bypassColor
        $svcLine = if (-not $svcInstalled) { 'not installed' } elseif ($svcRunning) { 'running' } else { 'installed, stopped' }
        Print-Status 'Win service:'    $svcLine ($(if ($svcRunning) { 'Green' } else { 'DarkGray' }))
        Print-Status 'WARP:'           $warpStr $warpCol
        Print-Status 'PAC:'            ($(if ($pac) { 'active' } else { 'off' })) ($(if ($pac) { 'Green' } else { 'DarkGray' }))

        Write-Host ''
        Write-Host '  :: BYPASS (zapret + WARP combined)' -ForegroundColor Magenta
        Write-Host '     1. Toggle DPI services'
        Write-Host '     2. Toggle Geo-blocked services (PAC routing via WARP)'
        Write-Host '     3. Pick strategy'
        Write-Host '     4. Start bypass (apply services + start winws + WARP if auto-start ON)'
        Write-Host '     5. Stop bypass (winws + WARP + PAC)'
        Write-Host ''
        Write-Host '  :: AUTOSTART' -ForegroundColor Magenta
        Write-Host '     6. Open service.bat (install/remove Windows service, advanced)'
        Write-Host ''
        Write-Host '  :: ADDITIONAL ROUTING' -ForegroundColor Magenta
        Write-Host '     7. Cloudflare WARP'
        Write-Host '     8. Custom VPN / Proxy (your own)'
        Write-Host ''
        Write-Host '  :: TOOLS' -ForegroundColor Magenta
        Write-Host '     9. Edit custom DPI domain list'
        Write-Host '    10. Update domain lists from upstream'
        Write-Host '    11. Run diagnostics (via service.bat)'
        Write-Host '    12. Connectivity smoke-test (DPI + WARP + PAC + Geo)'
        Write-Host ''
        Write-Host '     G. Open WPF GUI'
        Write-Host '     0. Exit'

        $c = (Read-MenuChoice).Trim().ToUpper()
        switch ($c) {
            '0' { return }
            ''  { }
            '1' { Show-ServicesMenu $cfg; Apply-Services $cfg }
            '2' { Show-GeoMenu $cfg }
            '3' { Show-StrategyMenu $cfg }
            '4' {
                $r = Start-Combined $cfg
                Write-Host "  $($r.Message)" -ForegroundColor $(if ($r.Success) { 'Green' } else { 'Red' })
                Pause-Key
            }
            '5' { Stop-Combined $cfg; Write-Host '  Stopped.' -ForegroundColor Yellow; Pause-Key }
            '6' { Run-Diagnostics }
            '7' { Show-WarpMenu $cfg }
            '8' { Show-CustomVpnMenu $cfg }
            '9' { Open-CustomDomains; Pause-Key }
            '10' { Update-Lists; Pause-Key }
            '11' { Run-Diagnostics }
            '12' {
                Write-Host '  Running connectivity smoke-test (this takes ~10 seconds)...' -ForegroundColor Yellow
                $t = Test-Connectivity $cfg
                foreach ($k in 'PacServer','Warp','Dpi','Geo') {
                    $row = $t[$k]
                    $col = if ($row.Ok) { 'Green' } else { 'Yellow' }
                    Print-Status "$($k):" "$(if ($row.Ok) { 'OK' } else { 'fail' }) — $($row.Detail)" $col
                }
                Pause-Key
            }
            'G' {
                $gui = Join-Path $UtilsDir 'launcher.gui.ps1'
                Start-Process powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $gui)
                return
            }
        }
    }
}

# ============================================================================
# Entry point
# ============================================================================
try {
    if (-not (Test-Path $ListsDir)) { throw "lists/ dir not found at $ListsDir" }
    if (-not (Test-Path $BinDir))   { throw "bin/ dir not found at $BinDir" }
    Show-MainMenu
} catch {
    Write-Host ''
    Write-Host "  FATAL: $_" -ForegroundColor Red
    Write-Host ''
    Pause-Key 'Press Enter to exit...'
    exit 1
}
