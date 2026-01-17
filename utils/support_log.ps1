param (
    [string]$LocalVersion = "Unknown",
    [string]$RootPath = ".\"
)

$CleanPath = $RootPath.TrimEnd('\').TrimEnd('.').TrimEnd('\').Trim('"')
$LogsFolder = Join-Path $CleanPath "utils\logs"
if (-not (Test-Path $LogsFolder)) { New-Item -ItemType Directory -Path $LogsFolder | Out-Null }

$Timestamp = Get-Date -Format "dd.MM.yyyy_HH-mm-ss"
$LogFileName = "logs_result_$Timestamp.txt"
$LogFile = Join-Path $LogsFolder $LogFileName

$Utf8WithBom = New-Object System.Text.UTF8Encoding $True

function Mask-IP($ip) {
    if ($ip -match '(\d+\.\d+\.\d+)\.\d+') {
        return "$($Matches[1]).xxx"
    }
    return $ip
}

try {
    $Content = New-Object System.Collections.Generic.List[string]
    $SubLine = "─" * 60

    $Content.Add("")
    $Content.Add("╔════════════════════════════════════════════════════════════════════╗")
    $Content.Add("║                       SYSTEM DIAGNOSTIC REPORT                                              ║")
    $Content.Add("╠════════════════════════════════════════════════════════════════════╣")
    $Content.Add("║ Generated: $(Get-Date -Format 'dd.MM.yyyy HH:mm:ss')                                         ║")
    $Content.Add("╚════════════════════════════════════════════════════════════════════╝")
    $Content.Add("")

    $Content.Add("┌──────────────────────────────────────────────────────────────────────┐")
    $Content.Add("│ 1. SYSTEM INFORMATION                                                                          │")
    $Content.Add("└──────────────────────────────────────────────────────────────────────┘")
    $Content.Add("")

    $VerStatus = ""
    try {
        $GitHubUrl = "https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/main/.service/version.txt"
        $RemoteVersion = (Invoke-WebRequest -Uri $GitHubUrl -UseBasicParsing -TimeoutSec 5).Content.Trim()
        $VerStatus = if ($RemoteVersion -ne $LocalVersion) { "⚠ UPDATE REQUIRED" } else { "✓ Latest" }
    } catch { $VerStatus = "⚠ Update check failed" }
    $Content.Add("    ┌─ Utility Information")
    $Content.Add("    ├─ Version         : $LocalVersion [$VerStatus]")
    $Content.Add("    └─ Path            : $CleanPath")

    $RegWin = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
    $WinVer = "$($RegWin.ProductName) $($RegWin.DisplayVersion) (Build $($RegWin.CurrentBuild).$($RegWin.UBR))"
    $Content.Add("    ┌─ Operating System")
    $Content.Add("    ├─ Windows         : $WinVer")
    
    $ISP = "N/A"
    try {
        $ISP = (Invoke-WebRequest -Uri "https://ipinfo.io/org" -UseBasicParsing -TimeoutSec 5).Content.Trim() -replace '^AS\d+\s+', ''
    } catch { }
    $Content.Add("    ├─ ISP Provider    : $ISP")
    
    $BrowserName = "N/A"
    $BrowserVer = "N/A"
    try {
        $ProgId = (Get-ItemProperty "HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\http\UserChoice" -ErrorAction SilentlyContinue).ProgId
        if ($ProgId -match "Chrome") {
            $BrowserName = "Google Chrome"
            $BPath = "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe"
            if (-not (Test-Path $BPath)) { $BPath = "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe" }
        } elseif ($ProgId -match "MSEdge") {
            $BrowserName = "Microsoft Edge"
            $BPath = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
        } elseif ($ProgId -match "Firefox") {
            $BrowserName = "Mozilla Firefox"
            $BPath = "${env:ProgramFiles}\Mozilla Firefox\firefox.exe"
        } elseif ($ProgId -match "Brave") {
            $BrowserName = "Brave"
            $BPath = "${env:ProgramFiles}\BraveSoftware\Brave-Browser\Application\brave.exe"
        } elseif ($ProgId -match "Opera") {
            $BrowserName = "Opera"
        }

        if ($BPath -and (Test-Path $BPath)) {
            $BrowserVer = (Get-Item $BPath).VersionInfo.ProductVersion
        }
    } catch { }
    $Content.Add("    └─ Browser         : $BrowserName ($BrowserVer)")

    $Content.Add("")
    $Content.Add("    ┌─ Path Analysis")
    if ($CleanPath -match "[\u0400-\u04FF]") {
        $Content.Add("    ├─ ⚠ WARNING: Cyrillic characters detected! WinDivert may fail.")
    }
    if ($CleanPath -match "OneDrive") {
        $Content.Add("    ├─ ⚠ WARNING: Folder in OneDrive. Syncing may block driver loading.")
    }

    $Nbsp = [char]160
    if ($CleanPath -match $Nbsp -or $CleanPath -match "^\s|\s$") { 
        $Content.Add("    └─ ⚠ WARNING: Hidden spaces detected in path") 
    } else {
        $Content.Add("    └─ ✓ Path format OK")
    }
    $Content.Add("")

    $Content.Add("┌──────────────────────────────────────────────────────────────────────┐")
    $Content.Add("│ 2. SERVICE STATUS                                                                              │")
    $Content.Add("└──────────────────────────────────────────────────────────────────────┘")
    $Content.Add("")
    
    $zSrv = Get-Service -Name "zapret" -ErrorAction SilentlyContinue
    $zStat = if ($zSrv -and $zSrv.Status -eq 'Running') { "✓ RUNNING" } else { "✗ NOT RUNNING" }
    
    $wdSrv = Get-Service -Name "WinDivert" -ErrorAction SilentlyContinue
    $wdStat = if ($wdSrv -and $wdSrv.Status -eq 'Running') { "✓ RUNNING" } else { "✗ NOT RUNNING" }
    
    $wsActive = if (Get-Process -Name "winws" -ErrorAction SilentlyContinue) { "✓ RUNNING" } else { "✗ NOT RUNNING" }
    
    $Content.Add("    ┌─ Core Services")
    $Content.Add("    ├─ zapret          : $zStat")
    $Content.Add("    ├─ WinDivert       : $wdStat")
    $Content.Add("    └─ Bypass (winws)  : $wsActive")
    
    $Content.Add("")
    $Content.Add("    ┌─ Process Count")
    $wsProcs = Get-Process -Name "winws" -ErrorAction SilentlyContinue
    $wsCount = if ($wsProcs) { $wsProcs.Count } else { 0 }
    $Content.Add("    └─ winws.exe instances : $wsCount")
    if ($wsCount -gt 1) { 
        $Content.Add("        ⚠ WARNING: Multiple instances! Driver conflicts possible.")
    }
    $Content.Add("")

    $Content.Add("┌──────────────────────────────────────────────────────────────────────┐")
    $Content.Add("│ 3. UTILITY CONFIGURATION                                                                       │")
    $Content.Add("└──────────────────────────────────────────────────────────────────────┘")
    $Content.Add("")
    
    $RegPath = "HKLM:\System\CurrentControlSet\Services\zapret"
    $Strategy = "N/A"
    if (Test-Path $RegPath) {
        $val = (Get-ItemProperty -Path $RegPath -Name "zapret-discord-youtube" -ErrorAction SilentlyContinue)."zapret-discord-youtube"
        if ($val) { $Strategy = $val }
    }
    
    $GF = if (Test-Path (Join-Path $CleanPath "utils\game_filter.enabled")) { "✓ enabled" } else { "✗ disabled" }
    
    $IPSetMode = "none"
    $IPPath = Join-Path $CleanPath "lists\ipset-all.txt"
    if (Test-Path $IPPath) {
        $linesCount = (Get-Content $IPPath | Measure-Object).Count
        $IPSetMode = if ($linesCount -gt 1) { "✓ loaded ($linesCount entries)" } else { "empty" }
    }
    
    $AU = if (Test-Path (Join-Path $CleanPath "utils\check_updates.enabled")) { "✓ enabled" } else { "✗ disabled" }
    
    $Content.Add("    ┌─ Configuration Settings")
    $Content.Add("    ├─ Service Strategy : $Strategy")
    $Content.Add("    ├─ Game Filter      : $GF")
    $Content.Add("    ├─ IPSet Filter     : $IPSetMode")
    $Content.Add("    └─ Auto-Update      : $AU")
    $Content.Add("")

    $Content.Add("┌──────────────────────────────────────────────────────────────────────┐")
    $Content.Add("│ 4. NETWORK CHECKS                                                                              │")
    $Content.Add("└──────────────────────────────────────────────────────────────────────┘")
    $Content.Add("")

    $Content.Add("    ┌─ DNS Resolution & Spoofing Check")
    $DomainsToCheck = @("discord.com", "googlevideo.com")
    $PublicDNS = "8.8.8.8"
    
    foreach ($Domain in $DomainsToCheck) {
        $SystemIP = "N/A"
        try {
            $SystemIP = [System.Net.Dns]::GetHostAddresses($Domain)[0].IPAddressToString
        } catch { }
        
        $PublicIP = "N/A"
        try {
            $Resolve = Resolve-DnsName -Name $Domain -Server $PublicDNS -ErrorAction SilentlyContinue
            $PublicIP = $Resolve.IPAddress[0]
        } catch { }
        
        $Status = if ($SystemIP -ne "N/A" -and $PublicIP -ne "N/A" -and $SystemIP -ne $PublicIP) {
            "⚠ DNS SPOOFING DETECTED"
        } else {
            "✓ OK"
        }
        
        $Content.Add("    ├─ $Domain")
        $Content.Add("    │  ├─ System DNS : $(Mask-IP $SystemIP)")
        $Content.Add("    │  ├─ Public DNS : $(Mask-IP $PublicIP)")
        $Content.Add("    │  └─ Status     : $Status")
    }
    $Content.Add("    └─")

    $Content.Add("")
    $Content.Add("    ┌─ Connectivity & Latency (Ping)")
    $PingTargets = @("1.1.1.1", "google.com", "discord.com")
    
    foreach ($Target in $PingTargets) {
        try {
            $DisplayName = Mask-IP $Target
            $PingResult = Test-Connection -ComputerName $Target -Count 2 -ErrorAction SilentlyContinue
            if ($PingResult) {
                $AvgRTT = ($PingResult | Measure-Object -Property ResponseTime -Average).Average
                $Content.Add("    ├─ $DisplayName : ✓ Reachable ([$( [Math]::Round($AvgRTT) )]ms)")
            } else {
                $Content.Add("    ├─ $DisplayName : ✗ Timed Out")
            }
        } catch {
            $Content.Add("    ├─ $Target : ✗ N/A")
        }
    }
    $Content.Add("    └─")

    $Content.Add("")
    $Content.Add("    ┌─ HTTP Connectivity Test")
    $WebTargets = @("https://discord.com", "https://www.youtube.com")
    foreach ($Url in $WebTargets) {
        try {
            $req = Invoke-WebRequest -Uri $Url -Method Head -TimeoutSec 5 -ErrorAction Stop -UseBasicParsing
            $Content.Add("    ├─ $Url : ✓ HTTP $($req.StatusCode)")
        } catch {
            $Content.Add("    ├─ $Url : ✗ FAILED ($($_.Exception.Message))")
        }
    }
    $Content.Add("    └─")

    $Content.Add("")
    $Content.Add("    ┌─ TTL Distance & DPI Detection")
    try {
        $BasePing = Test-Connection -ComputerName 8.8.8.8 -Count 1 -ErrorAction SilentlyContinue
        $BaseTTL = if ($BasePing) { $BasePing.ResponseTimeToLive } else { 0 }
        $Content.Add("    ├─ Baseline TTL (8.8.8.8) : $BaseTTL")
        
        $Targets = @("discord.com", "googlevideo.com")
        foreach ($Target in $Targets) {
            $TPing = Test-Connection -ComputerName $Target -Count 1 -ErrorAction SilentlyContinue
            $T_TTL = if ($TPing) { $TPing.ResponseTimeToLive } else { "N/A" }
            
            $DPIAlert = if ($T_TTL -eq 64 -or $T_TTL -eq 128 -or $T_TTL -eq 255) {
                " ⚠ SUSPECTED DPI INJECTION"
            } else { "" }
            
            $Content.Add("    ├─ $Target : TTL $T_TTL$DPIAlert")
        }
        $Content.Add("    └─")
    } catch { $Content.Add("    └─ TTL Analysis : ✗ N/A") }
    $Content.Add("")

    $Content.Add("┌──────────────────────────────────────────────────────────────────────┐")
    $Content.Add("│ 5. SYSTEM CONFIGURATION                                                                        │")
    $Content.Add("└──────────────────────────────────────────────────────────────────────┘")
    $Content.Add("")

    $Content.Add("    ┌─ Hosts File Check")
    try {
        $hostsPath = "C:\Windows\System32\drivers\etc\hosts"
        $hostsContent = Get-Content $hostsPath -ErrorAction SilentlyContinue
        $hostsEntry = if ($hostsContent -match "discord|youtube|googlevideo") { 
            "⚠ MANUAL ENTRIES PRESENT" 
        } else { 
            "✓ No conflicts" 
        }
        $Content.Add("    └─ Status : $hostsEntry")
    } catch { $Content.Add("    └─ Status : ✗ N/A") }

    $Content.Add("")
    $Content.Add("    ┌─ IPv6 Status")
    $ipv6Interfaces = Get-NetIPInterface -AddressFamily IPv6 -ConnectionState Connected -ErrorAction SilentlyContinue
    $v6Status = if ($ipv6Interfaces) { "⚠ ENABLED (May bypass zapret)" } else { "✓ Disabled" }
    $Content.Add("    └─ Dual Stack : $v6Status")

    $Content.Add("")
    $Content.Add("    ┌─ Firewall Rule")
    $fwRule = Get-NetFirewallRule -DisplayName "*winws*" -ErrorAction SilentlyContinue
    $fwStatus = if ($fwRule) { "✓ Found" } else { "⚠ NOT FOUND" }
    $Content.Add("    └─ winws Rule : $fwStatus")

    $Content.Add("")
    $Content.Add("    ┌─ Discord Features")
    $FullCmd = "N/A"
    $zRegPath = "HKLM:\System\CurrentControlSet\Services\zapret"
    if (Test-Path $zRegPath) {
        $FullCmd = (Get-ItemProperty $zRegPath -ErrorAction SilentlyContinue).ImagePath
        if (-not $FullCmd) { $FullCmd = "N/A" }
    }
    
    $dPortsRes = if ($FullCmd -match "2053|8443") { "✓ Present" } else { "⚠ MISSING" }
    $Content.Add("    ├─ Command Line : $FullCmd")
    $Content.Add("    └─ Voice/Video Ports : $dPortsRes")

    $Content.Add("")
    $Content.Add("    ┌─ QUIC Protocol Handling")
    $QuicCheck = if ($FullCmd -match "quic|udp-filter") { "✓ Handled" } else { "⚠ NOT HANDLED" }
    $Content.Add("    └─ Status : $QuicCheck")

    $Content.Add("")
    $Content.Add("    ┌─ TCP Settings")
    try {
        $tcpInfo = Get-NetTCPSetting -SettingName Internet -ErrorAction SilentlyContinue | Select-Object -First 1
        
        $ecnVal = if ($null -ne $tcpInfo.EcnCapability) { $tcpInfo.EcnCapability } else { "N/A" }
        $tfoVal = if ($null -ne $tcpInfo.FastOpen) { $tcpInfo.FastOpen } else { "N/A" }
        $ccVal  = if ($null -ne $tcpInfo.CongestionProvider) { $tcpInfo.CongestionProvider } else { "N/A" }
        
        $Content.Add("    ├─ ECN (Explicit Congestion Notification) : $ecnVal")
        $Content.Add("    ├─ TCP Fast Open (TFO)                    : $tfoVal")
        $Content.Add("    └─ Congestion Control Provider            : $ccVal")
    } catch { $Content.Add("    └─ Failed to collect TCP parameters") }

    $Content.Add("")
    $Content.Add("    ┌─ TCP 1323 Options (Timestamps)")
    try {
        $tcpRegPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters"
        $tcp1323 = (Get-ItemProperty -Path $tcpRegPath -Name "Tcp1323Opts" -ErrorAction SilentlyContinue).Tcp1323Opts
        
        $tStatus = "N/A (System Default)"
        if ($tcp1323 -eq 1) { $tStatus = "Timestamps Only" }
        elseif ($tcp1323 -eq 2) { $tStatus = "Window Scaling Only" }
        elseif ($tcp1323 -eq 3) { $tStatus = "Timestamps & Scaling ENABLED" }
        
        $Content.Add("    └─ Tcp1323Opts Value : $tStatus")
    } catch { $Content.Add("    └─ Check Failed : N/A") }
    $Content.Add("")

    $Content.Add("┌──────────────────────────────────────────────────────────────────────┐")
    $Content.Add("│ 6. CONFLICT DETECTION                                                                          │")
    $Content.Add("└──────────────────────────────────────────────────────────────────────┘")
    $Content.Add("")
    
    $bfeObj = Get-Service -Name "BFE" -ErrorAction SilentlyContinue
    $bfeRes = if ($bfeObj -and $bfeObj.Status -eq 'Running') { "✓ Running" } else { "✗ FAILED" }
    
    $proxyVal = (Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -ErrorAction SilentlyContinue).ProxyEnable
    $proxyRes = if ($proxyVal -eq 1) { "⚠ ENABLED" } else { "✓ Disabled" }
    
    $tcpObj = Get-NetTCPSetting -SettingName Internet -ErrorAction SilentlyContinue | Select-Object -First 1
    $tcpRes = if ($tcpObj -and $tcpObj.Timestamps -eq 'Enabled') { "✓ Enabled" } else { "✗ Disabled" }
    
    $adgRes = if (Get-Process -Name "AdguardSvc" -ErrorAction SilentlyContinue) { "✗ FAILED" } else { "✓ Not found" }
    $kilRes = if (Get-Service -Name "*Killer*" -ErrorAction SilentlyContinue) { "✗ FAILED" } else { "✓ Not found" }
    $intRes = if (Get-Service -Name "*IntelConnectivity*" -ErrorAction SilentlyContinue) { "✗ FAILED" } else { "✓ Not found" }
    $cpRes  = if (Get-Service -Name "TracSrvWrapper", "EPWD" -ErrorAction SilentlyContinue) { "✗ FAILED" } else { "✓ Not found" }
    $smbRes = if (Get-Service -Name "*SmartByte*" -ErrorAction SilentlyContinue) { "✗ FAILED" } else { "✓ Not found" }
    $vpnRes = if (Get-Service -Name "*VPN*", "*WireGuard*", "*OpenVPN*" -ErrorAction SilentlyContinue) { "✗ FAILED" } else { "✓ Not found" }
    
    $Content.Add("    ┌─ System Services")
    $Content.Add("    ├─ Base Filtering Engine      : $bfeRes")
    $Content.Add("    └─ System Proxy               : $proxyRes")
    
    $Content.Add("")
    $Content.Add("    ┌─ TCP Configuration")
    $Content.Add("    └─ TCP Timestamps             : $tcpRes")
    
    $Content.Add("")
    $Content.Add("    ┌─ Software Conflicts")
    $Content.Add("    ├─ Adguard                    : $adgRes")
    $Content.Add("    ├─ Killer Network             : $kilRes")
    $Content.Add("    ├─ Intel Connectivity         : $intRes")
    $Content.Add("    ├─ Check Point VPN            : $cpRes")
    $Content.Add("    ├─ SmartByte                  : $smbRes")
    $Content.Add("    └─ VPN/Tunnel Services        : $vpnRes")

    $Content.Add("")
    $Content.Add("    ┌─ Virtual Adapters (TUN/TAP)")
    try {
        $vAdapters = Get-CimInstance -ClassName Win32_NetworkAdapter -ErrorAction SilentlyContinue | Where-Object { 
            $_.Name -match "TUN|TAP|WireGuard|Amnezia|Tailscale|ZeroTier|Cloudflare" 
        }
        
        if ($vAdapters) {
            $Content.Add("    ├─ ⚠ CONFLICTS FOUND:")
            foreach ($va in $vAdapters) {
                $vStatus = if ($va.NetConnectionStatus -eq 2) { "Connected" } else { "Disconnected" }
                $Content.Add("    │  └─ $($va.Name) [$vStatus]")
            }
            $Content.Add("    └─")
        } else {
            $Content.Add("    └─ ✓ No conflicts detected")
        }
    } catch { $Content.Add("    └─ ✗ Check failed") }
    $Content.Add("")

    $Content.Add("┌──────────────────────────────────────────────────────────────────────┐")
    $Content.Add("│ 7. SECURITY & DRIVER CHECKS                                                                    │")
    $Content.Add("└──────────────────────────────────────────────────────────────────────┘")
    $Content.Add("")

    $Content.Add("    ┌─ Antivirus Status")
    $Defender = Get-Service -Name "WinDefend" -ErrorAction SilentlyContinue
    $DefStat = if ($Defender -and $Defender.Status -eq 'Running') { "⚠ ACTIVE" } else { "✓ Disabled" }
    $Content.Add("    ├─ Windows Defender : $DefStat")
    
    $AVList = Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction SilentlyContinue
    $AVName = if ($AVList) { $AVList.displayName -join ", " } else { "None" }
    $Content.Add("    └─ Installed AV     : $AVName")

    $Content.Add("")
    $Content.Add("    ┌─ WinDivert Driver Validation")
    try {
        $DriverPath = Join-Path $CleanPath "bin\WinDivert64.sys"
        if (Test-Path $DriverPath) {
            $Signature = Get-AuthenticodeSignature $DriverPath
            $SigStatus = if ($Signature.Status -eq "Valid") { "✓ Valid" } else { "✗ FAILED ($($Signature.Status))" }
            $Content.Add("    └─ Digital Signature : $SigStatus")
        } else {
            $Content.Add("    └─ ✗ MISSING")
        }
    } catch { $Content.Add("    └─ ✗ Validation failed") }

    $Content.Add("")
    $Content.Add("    ┌─ Network Offloading")
    try {
        $Offload = Get-NetAdapterAdvancedProperty -RegistryKeyword "*LsoV2IPv4" -ErrorAction SilentlyContinue
        $LsoStatus = if ($Offload -and $Offload.DisplayValue -eq "Enabled") { "⚠ ENABLED" } else { "✓ Disabled" }
        $Content.Add("    └─ Large Send Offload (LSO) : $LsoStatus")
    } catch { $Content.Add("    └─ ✗ N/A") }
    $Content.Add("")

    $Content.Add("┌──────────────────────────────────────────────────────────────────────┐")
    $Content.Add("│ 8. BROWSER & ECH STATUS                                                                        │")
    $Content.Add("└──────────────────────────────────────────────────────────────────────┘")
    $Content.Add("")
    
    $Content.Add("    ┌─ ECH (Encrypted ClientHello)")
    if ($BrowserName -match "Chrome|Edge|Brave") {
        $vParts = $BrowserVer.Split('.')
        if ($vParts.Count -gt 0 -and [int]$vParts[0] -ge 117) {
            $Content.Add("    ├─ ⚠ ALERT: Browser supports ECH")
            $Content.Add("    └─ Action: Disable 'Encrypted ClientHello' in browser flags")
        } else {
            $Content.Add("    └─ ✓ Browser version below ECH requirements")
        }
    } else {
        $Content.Add("    └─ ✓ Non-Chromium browser")
    }
    $Content.Add("")

    $Content.Add("┌──────────────────────────────────────────────────────────────────────┐")
    $Content.Add("│ 9. NETWORK INTERFACES                                                                          │")
    $Content.Add("└──────────────────────────────────────────────────────────────────────┘")
    $Content.Add("")
    
    try {
        $NetConfig = Get-NetIPConfiguration -Detailed
        $i = 0
        foreach ($adapter in $NetConfig) {
            if ($adapter.IPv4Address) {
                $i++
                $IPInterface = Get-NetIPInterface -InterfaceAlias $adapter.InterfaceAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue
                
                $status = if ($adapter.NetAdapter) { $adapter.NetAdapter.Status } else { "Unknown" }
                $statusIcon = if ($status -eq "Up") { "✓" } else { "✗" }
                
                $Content.Add("    ┌─ Interface #$i : $($adapter.InterfaceAlias) $statusIcon")
                $Content.Add("    │  ├─ Status      : $status")
                
                $maskedIP = Mask-IP $adapter.IPv4Address.IPv4Address
                $Content.Add("    │  ├─ IPv4 Address : $maskedIP")
                
                $dnsList = $adapter.DNSServer.ServerAddresses | ForEach-Object { Mask-IP $_ }
                $Content.Add("    │  ├─ DNS Servers  : $($dnsList -join ', ')")
                
                $mtuVal = if ($null -ne $IPInterface.NlMtuBytes) { $IPInterface.NlMtuBytes } else { "N/A" }
                $metVal = if ($null -ne $IPInterface.InterfaceMetric) { $IPInterface.InterfaceMetric } else { "N/A" }
                $Content.Add("    │  ├─ MTU          : $mtuVal")
                $Content.Add("    │  └─ Metric       : $metVal")
                
                if ($adapter.NetAdapter) {
                    $hw = "$($adapter.NetAdapter.DriverProvider) ($($adapter.NetAdapter.DriverVersion))"
                    $Content.Add("    │    └─ Driver      : $hw")
                }
                
                if ($i -lt @($NetConfig).Count) {
                    $Content.Add("    │")
                }
            }
        }
        if ($i -eq 0) {
            $Content.Add("    └─ No network interfaces found")
        }
    } catch { 
        $Content.Add("    └─ ✗ Error gathering network interface data")
    }

    [System.IO.File]::WriteAllLines($LogFile, $Content, $Utf8WithBom)
    Write-Host "Diagnostic report saved utils/logs: $LogFileName" -ForegroundColor Green
    notepad.exe $LogFile

} catch {
    Write-Host "Fatal Error: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}