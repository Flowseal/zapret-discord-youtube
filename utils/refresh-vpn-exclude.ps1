# Writes the VPN endpoints zapret must leave alone.
# lists/ipset-exclude-vpn.txt is passed to winws --ipset-exclude.
# lists/wf-exclude-vpn.txt is a WinDivert partial filter, so those packets
# are not diverted at all. Both files are regenerated on every strategy start.
param(
    [Parameter(Mandatory = $true)]
    [string]$ListsDir
)

$ErrorActionPreference = 'Stop'

$processNames = @(
    'wireguard', 'warp-svc', 'warp-taskbar', 'Cloudflare WARP',
    'openvpn', 'openvpn-gui', 'openvpnserv', 'openvpnserv2',
    'outline', 'OutlineService', 'outline-client',
    'hysteria', 'sing-box', 'xray', 'wxray', 'v2ray', 'v2rayN', 'wv2ray',
    'clash', 'clash-meta', 'clash-core', 'clash-verge', 'clash-verge-service',
    'verge-mihomo', 'mihomo', 'mihomo-party', 'koala-clash', 'KoalaClash', 'Clash Verge',
    'nekoray', 'nekoray_core', 'nekobox', 'nekobox_core',
    'Hiddify', 'HiddifyCli', 'HiddifyNext', 'Happ', 'happd',
    'tun2socks', 'tailscale', 'tailscaled', 'zerotier-one', 'zerotier-one_x64',
    'nordvpn', 'nordlynx', 'nordvpn-service',
    'ProtonVPN', 'ProtonVPN.Client', 'ProtonVPNService',
    'Mullvad', 'mullvad-daemon', 'mullvad-vpn',
    'surfshark', 'surfshark-service', 'expressvpn', 'ExpressVPN', 'expressvpnd',
    'FortiTray', 'FortiSSLVPNdaemon', 'vpnagent', 'vpnui', 'openconnect',
    'vpnclient', 'vpnclient_x64', 'vpncmgr', 'vpncmgr_x64',
    'AmneziaVPN', 'AmneziaVPN-service', 'amneziawg', 'awg',
    'throne', 'Throne', 'sstap', 'SSTap', 'AdGuardVpn', 'adguardvpn'
)

$servicePattern = 'wireguard|amnezia|warp-svc|cloudflare.?warp|outline|openvpn|hiddify|sing-box|mihomo|xray|clash|happ|tailscale|zerotier|nordlynx|nordvpn|proton|mullvad|expressvpn|surfshark|forti|anyconnect|openconnect|hysteria|v2ray|nekoray|nekobox|tun2socks|koala|amneziawg|adguardvpn|sstap|throne'
$adapterPattern = 'wintun|wireguard|amnezia|outline|tap-windows|cloudflare|warp|nordlynx|mullvad|proton|tailscale|zerotier|sing-?box|mihomo|clash|tun2socks|openvpn|happ|hiddify|xray|v2ray|hysteria|koala|sstap|forti|anyconnect|expressvpn|surfshark|adguard'
$placeholder = '203.0.113.113/32'

function Test-PublicUnicast([string]$Text) {
    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($Text, [ref]$parsed)) {
        return $false
    }
    $bytes = $parsed.GetAddressBytes()
    if ($parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
        if ($bytes[0] -eq 0 -or $bytes[0] -eq 10 -or $bytes[0] -eq 127) { return $false }
        if ($bytes[0] -eq 169 -and $bytes[1] -eq 254) { return $false }
        if ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) { return $false }
        if ($bytes[0] -eq 192 -and $bytes[1] -eq 168) { return $false }
        if ($bytes[0] -eq 100 -and $bytes[1] -ge 64 -and $bytes[1] -le 127) { return $false }
        if ($bytes[0] -ge 224) { return $false }
        return $true
    }
    if ($parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetworkV6) {
        return $false
    }
    if ($parsed.IsIPv6LinkLocal -or $parsed.IsIPv6Multicast -or $parsed.IsIPv6SiteLocal) {
        return $false
    }
    $allZero = $true
    foreach ($byte in $bytes) {
        if ($byte -ne 0) { $allZero = $false; break }
    }
    if ($allZero -or ($bytes[15] -eq 1 -and -not ($bytes[0..14] | Where-Object { $_ -ne 0 }))) {
        return $false
    }
    if (($bytes[0] -band 0xfe) -eq 0xfc) { return $false }
    $mapped = $true
    for ($i = 0; $i -lt 10; $i++) {
        if ($bytes[$i] -ne 0) { $mapped = $false; break }
    }
    if ($mapped -and $bytes[10] -eq 0xff -and $bytes[11] -eq 0xff) {
        return $false
    }
    return $true
}

function Write-Utf8([string]$Path, [string]$Content) {
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, $Content, $utf8)
}

$lists = $ListsDir.Trim().Trim('"').TrimEnd('\')
if (-not (Test-Path -LiteralPath $lists)) {
    New-Item -ItemType Directory -Path $lists | Out-Null
}

$found = New-Object System.Collections.Generic.List[object]
$seen = @{}

function Add-Endpoint([string]$Raw, [string]$Source, [int]$ForcedPrefix) {
    if ([string]::IsNullOrWhiteSpace($Raw)) { return }
    $text = $Raw.Trim()
    if ($text -eq '*' -or $text -eq '0.0.0.0' -or $text -eq '::') { return }
    if ($text -match '^\[(.+)\]:(\d+)$') { $text = $Matches[1] }
    elseif ($text -match '^(\d{1,3}(?:\.\d{1,3}){3}):(\d+)$') { $text = $Matches[1] }

    $prefix = $ForcedPrefix
    if ($text -match '^(.+)/(\d+)$') {
        $text = $Matches[1]
        if ($prefix -le 0) { $prefix = [int]$Matches[2] }
    }
    if ($text.StartsWith('[') -and $text.EndsWith(']')) {
        $text = $text.Substring(1, $text.Length - 2)
    }
    if (-not (Test-PublicUnicast $text)) { return }

    $parsed = [System.Net.IPAddress]::Parse($text)
    $canonical = $parsed.IPAddressToString
    $isV6 = $parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6
    if ($prefix -le 0) { $prefix = $(if ($isV6) { 128 } else { 32 }) }
    $maxPrefix = $(if ($isV6) { 128 } else { 32 })
    if ($prefix -gt $maxPrefix) { return }

    $cidr = "$canonical/$prefix"
    if ($seen.ContainsKey($cidr) -or $cidr -eq $placeholder) { return }
    $seen[$cidr] = $true
    $found.Add([pscustomobject]@{
        Cidr   = $cidr
        Ip     = $canonical
        Prefix = $prefix
        IsV6   = $isV6
        Source = $Source
    })
}

try {
    $wanted = @{}
    foreach ($name in $processNames) { $wanted[$name.ToLowerInvariant()] = $true }

    $pidName = @{}
    Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
        $key = $_.ProcessName.ToLowerInvariant()
        if ($wanted.ContainsKey($key)) {
            $pidName[[int]$_.Id] = $_.ProcessName
        }
    }

    Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.ProcessId -gt 0 -and $_.PathName -and $_.PathName -match $servicePattern) {
            $procId = [int]$_.ProcessId
            if (-not $pidName.ContainsKey($procId)) {
                $pidName[$procId] = $_.Name
            }
        }
    }

    # A tunnel client has one or two server addresses. A core that connects
    # straight to many sites must not donate all of those destinations, or
    # zapret would skip them for every application.
    $byProcess = @{}
    foreach ($procId in @($pidName.Keys)) {
        $label = [string]$pidName[$procId]
        $bag = New-Object System.Collections.Generic.List[object]
        Get-NetTCPConnection -OwningProcess $procId -State Established -ErrorAction SilentlyContinue | ForEach-Object {
            $bag.Add([pscustomobject]@{ Remote = $_.RemoteAddress; Source = "$label tcp" })
        }
        Get-NetUDPEndpoint -OwningProcess $procId -ErrorAction SilentlyContinue | ForEach-Object {
            $bag.Add([pscustomobject]@{ Remote = $_.RemoteAddress; Source = "$label udp" })
        }
        $byProcess[$procId] = $bag
    }
    foreach ($procId in @($byProcess.Keys)) {
        $counts = @{}
        $sources = @{}
        foreach ($row in $byProcess[$procId]) {
            $ip = [string]$row.Remote
            if ([string]::IsNullOrWhiteSpace($ip)) { continue }
            if (-not $counts.ContainsKey($ip)) { $counts[$ip] = 0; $sources[$ip] = $row.Source }
            $counts[$ip]++
        }
        $publicIps = @($counts.Keys | Where-Object { Test-PublicUnicast $_ })
        if ($publicIps.Count -eq 0) { continue }
        $keep = $publicIps
        if ($publicIps.Count -gt 4) {
            $ranked = @($publicIps | Sort-Object { $counts[$_] } -Descending)
            $top = $ranked[0]
            $total = 0
            foreach ($ip in $publicIps) { $total += $counts[$ip] }
            if ($counts[$top] -ge 3 -and $counts[$top] * 2 -ge $total) {
                $keep = @($ranked | Where-Object { $counts[$_] -eq $counts[$top] } | Select-Object -First 2)
            } else {
                $keep = @()
            }
        }
        foreach ($ip in $keep) { Add-Endpoint $ip $sources[$ip] 0 }
    }

    $wgExes = @(
        "$env:ProgramFiles\WireGuard\wg.exe",
        "$(${env:ProgramFiles(x86)})\WireGuard\wg.exe",
        "$env:ProgramFiles\AmneziaWG\wg.exe",
        "$env:ProgramFiles\AmneziaVPN\wg.exe"
    )
    $wgCmd = Get-Command wg.exe -ErrorAction SilentlyContinue
    if ($wgCmd) { $wgExes += $wgCmd.Source }
    $wgRan = @{}
    foreach ($wgExe in $wgExes) {
        if (-not $wgExe -or $wgRan.ContainsKey($wgExe)) { continue }
        $wgRan[$wgExe] = $true
        if (-not (Test-Path -LiteralPath $wgExe)) { continue }
        $lines = @(& $wgExe show all endpoints 2>$null)
        foreach ($line in $lines) {
            $text = "$line"
            if ($text -match '\[([0-9a-fA-F:]+)\]:\d+') {
                Add-Endpoint $Matches[1] 'wg' 0
            } elseif ($text -match '(\d{1,3}(?:\.\d{1,3}){3}):\d+') {
                Add-Endpoint $Matches[1] 'wg' 0
            }
        }
    }

    if ($found.Count -eq 0) {
        $vpnIf = @{}
        Get-NetAdapter -ErrorAction SilentlyContinue | ForEach-Object {
            $blob = $_.Name + ' ' + $_.InterfaceDescription
            if ($_.Status -eq 'Up' -and $blob -match $adapterPattern) {
                $vpnIf[[int]$_.ifIndex] = $_.Name
            }
        }
        if ($vpnIf.Count -gt 0) {
            $defaultRoute = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                Sort-Object RouteMetric, InterfaceMetric |
                Select-Object -First 1
            if ($defaultRoute -and -not $vpnIf.ContainsKey([int]$defaultRoute.InterfaceIndex)) {
                $candidates = New-Object System.Collections.Generic.List[string]
                Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object {
                    if ($_.DestinationPrefix -match '/32$' -and
                        [int]$_.InterfaceIndex -eq [int]$defaultRoute.InterfaceIndex -and
                        $_.NextHop -and $_.NextHop -ne '0.0.0.0') {
                        $ip = $_.DestinationPrefix.Split('/')[0]
                        if ((Test-PublicUnicast $ip) -and -not $candidates.Contains($ip)) {
                            $candidates.Add($ip)
                        }
                    }
                }
                if ($candidates.Count -ge 1 -and $candidates.Count -le 4) {
                    foreach ($ip in $candidates) { Add-Endpoint $ip 'route' 0 }
                }
            }
        }
    }

    $userFile = Join-Path $lists 'ipset-exclude-vpn-user.txt'
    if (-not (Test-Path -LiteralPath $userFile)) {
        Write-Utf8 $userFile ($placeholder + "`r`n")
    }
    foreach ($line in [System.IO.File]::ReadAllLines($userFile)) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0 -or $trimmed.StartsWith('#')) { continue }
        Add-Endpoint $trimmed 'user' 0
    }

    $cidrLines = New-Object System.Collections.Generic.List[string]
    foreach ($item in $found) { $cidrLines.Add($item.Cidr) }
    if ($cidrLines.Count -eq 0) { $cidrLines.Add($placeholder) }

    $kernel = @($found | Where-Object { (-not $_.IsV6 -and $_.Prefix -eq 32) -or ($_.IsV6 -and $_.Prefix -eq 128) } | Select-Object -First 24)
    $filterParts = @()
    $v4 = @($kernel | Where-Object { -not $_.IsV6 })
    $v6 = @($kernel | Where-Object { $_.IsV6 })
    if ($v4.Count -gt 0) {
        $cmp = ($v4 | ForEach-Object { "ip.DstAddr != $($_.Ip)" }) -join ' and '
        $filterParts += "(not ip or ($cmp))"
    }
    if ($v6.Count -gt 0) {
        $cmp = ($v6 | ForEach-Object { "ipv6.DstAddr != $($_.Ip)" }) -join ' and '
        $filterParts += "(not ipv6 or ($cmp))"
    }
    $filter = 'true'
    if ($filterParts.Count -gt 0) { $filter = $filterParts -join ' and ' }

    Write-Utf8 (Join-Path $lists 'ipset-exclude-vpn.txt') (($cidrLines -join "`r`n") + "`r`n")
    Write-Utf8 (Join-Path $lists 'wf-exclude-vpn.txt') ($filter + "`r`n")

    $report = New-Object System.Collections.Generic.List[string]
    $report.Add('# generated ' + [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))
    if ($found.Count -eq 0) {
        $report.Add('# no tunnel endpoints detected')
    } else {
        foreach ($item in $found) { $report.Add("$($item.Cidr)  $($item.Source)") }
    }
    $report.Add('# single hosts are also excluded in WinDivert; wider networks are excluded by ipset only')
    $report.Add('# add your own CIDRs to ipset-exclude-vpn-user.txt and start the strategy again')
    Write-Utf8 (Join-Path $lists 'vpn-exclude-report.txt') (($report -join "`r`n") + "`r`n")

    if ($found.Count -eq 0) {
        Write-Output 'VPN exclude: no tunnel endpoints detected'
    } else {
        $shown = @($found | Select-Object -First 8 | ForEach-Object { "$($_.Ip) ($($_.Source))" })
        $suffix = ''
        if ($found.Count -gt 8) { $suffix = " and $($found.Count - 8) more" }
        Write-Output ('VPN exclude: ' + ($shown -join ', ') + $suffix)
    }
    exit 0
} catch {
    Write-Output ("VPN exclude: " + $_.Exception.Message)
    exit 1
}
