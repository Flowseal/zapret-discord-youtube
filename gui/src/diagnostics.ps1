# Zapret GUI - Diagnostics Functions

class DiagnosticResult {
    [string]$Name
    [string]$Status  # OK, Warning, Error
    [string]$Message
    [string]$HelpUrl
    
    DiagnosticResult([string]$n, [string]$s, [string]$m, [string]$h = "") {
        $this.Name = $n
        $this.Status = $s
        $this.Message = $m
        $this.HelpUrl = $h
    }
}

function Invoke-Diagnostics {
    $results = @()
    
    # 1. BFE Check
    try {
        $bfe = sc.exe query BFE 2>&1
        if (($bfe -join "`n") -match "RUNNING") {
            $results += [DiagnosticResult]::new("Base Filtering Engine", "OK", "BFE is running")
        } else {
            $results += [DiagnosticResult]::new("Base Filtering Engine", "Error", "BFE is not running")
        }
    } catch {
        $results += [DiagnosticResult]::new("Base Filtering Engine", "Error", "Could not check BFE")
    }
    
    # 2. Proxy Check
    try {
        $proxy = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -Name ProxyEnable -ErrorAction SilentlyContinue
        if ($proxy -and $proxy.ProxyEnable -eq 1) {
            $results += [DiagnosticResult]::new("System Proxy", "Warning", "Proxy is enabled")
        } else {
            $results += [DiagnosticResult]::new("System Proxy", "OK", "No proxy configured")
        }
    } catch {
        $results += [DiagnosticResult]::new("System Proxy", "OK", "Proxy check passed")
    }
    
    # 3. TCP Timestamps
    try {
        $tcp = netsh interface tcp show global 2>&1
        if (($tcp -join "`n") -match "timestamps.*enabled" -or ($tcp -join "`n") -match "Timestamps.*enabled") {
            $results += [DiagnosticResult]::new("TCP Timestamps", "OK", "Enabled")
        } else {
            $null = netsh interface tcp set global timestamps=enabled 2>&1
            $results += [DiagnosticResult]::new("TCP Timestamps", "Warning", "Was disabled, now enabled")
        }
    } catch {
        $results += [DiagnosticResult]::new("TCP Timestamps", "Warning", "Could not check")
    }
    
    # 4. Adguard
    try {
        $adguard = Get-Process -Name "AdguardSvc" -ErrorAction SilentlyContinue
        if ($adguard) {
            $results += [DiagnosticResult]::new("Adguard", "Error", "May cause problems", "https://github.com/Flowseal/zapret-discord-youtube/issues/417")
        } else {
            $results += [DiagnosticResult]::new("Adguard", "OK", "Not detected")
        }
    } catch {
        $results += [DiagnosticResult]::new("Adguard", "OK", "Check passed")
    }
    
    # 5. Killer Services
    try {
        $sc = sc.exe query 2>&1
        if (($sc -join "`n") -match "Killer") {
            $results += [DiagnosticResult]::new("Killer Services", "Error", "Conflicts with zapret", "https://github.com/Flowseal/zapret-discord-youtube/issues/2512")
        } else {
            $results += [DiagnosticResult]::new("Killer Services", "OK", "Not detected")
        }
    } catch {
        $results += [DiagnosticResult]::new("Killer Services", "OK", "Check passed")
    }
    
    # 6. Intel Connectivity
    try {
        $sc = sc.exe query 2>&1
        if (($sc -join "`n") -match "Intel.*Connectivity") {
            $results += [DiagnosticResult]::new("Intel Connectivity", "Error", "Conflicts with zapret")
        } else {
            $results += [DiagnosticResult]::new("Intel Connectivity", "OK", "Not detected")
        }
    } catch {
        $results += [DiagnosticResult]::new("Intel Connectivity", "OK", "Check passed")
    }
    
    # 7. Check Point
    try {
        $sc = sc.exe query 2>&1
        if (($sc -join "`n") -match "TracSrvWrapper|EPWD") {
            $results += [DiagnosticResult]::new("Check Point", "Error", "Conflicts with zapret")
        } else {
            $results += [DiagnosticResult]::new("Check Point", "OK", "Not detected")
        }
    } catch {
        $results += [DiagnosticResult]::new("Check Point", "OK", "Check passed")
    }
    
    # 8. SmartByte
    try {
        $sc = sc.exe query 2>&1
        if (($sc -join "`n") -match "SmartByte") {
            $results += [DiagnosticResult]::new("SmartByte", "Error", "Conflicts with zapret")
        } else {
            $results += [DiagnosticResult]::new("SmartByte", "OK", "Not detected")
        }
    } catch {
        $results += [DiagnosticResult]::new("SmartByte", "OK", "Check passed")
    }
    
    # 9. VPN
    try {
        $sc = sc.exe query 2>&1
        if (($sc -join "`n") -match "VPN") {
            $results += [DiagnosticResult]::new("VPN Services", "Warning", "May conflict with zapret")
        } else {
            $results += [DiagnosticResult]::new("VPN Services", "OK", "Not detected")
        }
    } catch {
        $results += [DiagnosticResult]::new("VPN Services", "OK", "Check passed")
    }
    
    # 10. WinDivert driver
    $sysFiles = Get-ChildItem -Path $script:BinDir -Filter "*.sys" -ErrorAction SilentlyContinue
    if ($sysFiles -and $sysFiles.Count -gt 0) {
        $results += [DiagnosticResult]::new("WinDivert Driver", "OK", "Found in bin folder")
    } else {
        $results += [DiagnosticResult]::new("WinDivert Driver", "Error", "Not found in bin folder")
    }
    
    # 11. Conflicting bypasses
    $conflicts = @("GoodbyeDPI", "discordfix_zapret", "winws1", "winws2")
    $found = @()
    foreach ($svc in $conflicts) {
        $out = sc.exe query $svc 2>&1
        if (($out -join "`n") -notmatch "FAILED 1060") {
            $found += $svc
        }
    }
    if ($found.Count -gt 0) {
        $results += [DiagnosticResult]::new("Conflicting Bypasses", "Error", "Found: $($found -join ', ')")
    } else {
        $results += [DiagnosticResult]::new("Conflicting Bypasses", "OK", "None detected")
    }
    
    return $results
}

function Clear-DiscordCache {
    $discordProcess = Get-Process -Name "Discord" -ErrorAction SilentlyContinue
    if ($discordProcess) {
        Stop-Process -Name "Discord" -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
    }
    
    $discordDir = Join-Path $env:APPDATA "discord"
    $cacheDirs = @("Cache", "Code Cache", "GPUCache")
    
    foreach ($dir in $cacheDirs) {
        $path = Join-Path $discordDir $dir
        if (Test-Path $path) {
            try {
                Remove-Item -Path $path -Recurse -Force -ErrorAction Stop
            } catch {}
        }
    }
    
    return $true
}
