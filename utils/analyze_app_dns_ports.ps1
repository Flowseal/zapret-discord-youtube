param(
    [Parameter(Mandatory = $true)]
    [string]$ExePath,

    [Parameter(Mandatory = $false)]
    [int]$Duration = 120,

    [Parameter(Mandatory = $false)]
    [string]$ListPath = "",

    [Parameter(Mandatory = $false)]
    [string]$IpsetPath = ""
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor White
}

function Write-Ok {
    param([string]$Message)
    Write-Host "[OK]   $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-Err {
    param([string]$Message)
    Write-Host "[ERR]  $Message" -ForegroundColor Red
}

function Get-ChildProcessIds {
    param([int]$RootPid)

    $ids = New-Object "System.Collections.Generic.HashSet[int]"
    [void]$ids.Add($RootPid)

    try {
        $all = Get-CimInstance Win32_Process | Select-Object ProcessId, ParentProcessId
        $queue = New-Object System.Collections.Queue
        $queue.Enqueue($RootPid)

        while ($queue.Count -gt 0) {
            $parent = [int]$queue.Dequeue()
            $children = $all | Where-Object { $_.ParentProcessId -eq $parent }
            foreach ($child in $children) {
                $childId = [int]$child.ProcessId
                if ($ids.Add($childId)) {
                    $queue.Enqueue($childId)
                }
            }
        }
    }
    catch {
        Write-Warn "Cannot build full child process tree: $($_.Exception.Message)"
    }

    return @($ids | Sort-Object)
}

function Read-DomainsFromTsharkLine {
    param([string]$Line)

    $domains = New-Object "System.Collections.Generic.List[string]"
    if ([string]::IsNullOrWhiteSpace($Line)) {
        return @()
    }

    $parts = $Line -split "`t", 6
    if ($parts.Length -ge 4 -and -not [string]::IsNullOrWhiteSpace($parts[3])) {
        [void]$domains.Add($parts[3])
    }
    if ($parts.Length -ge 5 -and -not [string]::IsNullOrWhiteSpace($parts[4])) {
        foreach ($d in ($parts[4] -split ",")) {
            if (-not [string]::IsNullOrWhiteSpace($d)) {
                [void]$domains.Add($d)
            }
        }
    }

    if ($parts.Length -ge 6) {
        $info = "$($parts[5])"
        $domainMatches = [regex]::Matches($info, "(?i)([a-z0-9][a-z0-9.-]*\.[a-z]{2,})")
        foreach ($m in $domainMatches) {
            [void]$domains.Add($m.Groups[1].Value)
        }
    }

    $clean = New-Object "System.Collections.Generic.HashSet[string]" ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($d in $domains) {
        $item = "$d".Trim().TrimEnd('.').ToLowerInvariant()
        if ($item -match "^[a-z0-9][a-z0-9.-]*\.[a-z]{2,}$") {
            [void]$clean.Add($item)
        }
    }

    return @($clean)
}

function Resolve-ListPath {
    param([string]$UserPath)

    if (-not [string]::IsNullOrWhiteSpace($UserPath)) {
        return [System.IO.Path]::GetFullPath($UserPath)
    }

    $defaultPath = Join-Path $PSScriptRoot "..\lists\list-general-user.txt"
    return [System.IO.Path]::GetFullPath($defaultPath)
}

function Resolve-IpsetPath {
    param([string]$UserPath)

    if (-not [string]::IsNullOrWhiteSpace($UserPath)) {
        return [System.IO.Path]::GetFullPath($UserPath)
    }

    $defaultPath = Join-Path $PSScriptRoot "..\lists\ipset-all.txt"
    return [System.IO.Path]::GetFullPath($defaultPath)
}

function Initialize-ListFile {
    param([string]$Path)

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        "domain.example.abc" | Out-File -FilePath $Path -Encoding UTF8
    }
}

function Initialize-IpsetFile {
    param([string]$Path)

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        "" | Out-File -FilePath $Path -Encoding UTF8
    }
}

function Main {
    Write-Host ""
    Write-Host "=====================================================================" -ForegroundColor Cyan
    Write-Host " APP DNS + IP ANALYZER (single mode)" -ForegroundColor Cyan
    Write-Host "=====================================================================" -ForegroundColor Cyan
    Write-Host ""

    if ($Duration -lt 15) {
        Write-Warn "Duration too small, switched to 15 sec minimum"
        $script:Duration = 15
    }

    $resolvedExe = [Environment]::ExpandEnvironmentVariables($ExePath.Trim().Trim('"'))
    $resolvedExe = [System.IO.Path]::GetFullPath($resolvedExe)
    if (-not (Test-Path -LiteralPath $resolvedExe)) {
        Write-Err "EXE not found: $resolvedExe"
        exit 1
    }

    $exeName = [System.IO.Path]::GetFileNameWithoutExtension($resolvedExe)
    Write-Info "Target EXE: $resolvedExe"
    Write-Info "Duration: $Duration sec"

    $tsharkCmd = Get-Command "tshark.exe" -ErrorAction SilentlyContinue
    if (-not $tsharkCmd) {
        Write-Err "tshark.exe not found in PATH"
        Write-Warn "Install Wireshark with TShark and add it to PATH"
        Write-Host "Download: https://www.wireshark.org/download.html" -ForegroundColor Yellow
        $open = Read-Host "Open download page now? (Y/N, default: Y)"
        if ([string]::IsNullOrWhiteSpace($open) -or $open -match "^(?i)y$") {
            Start-Process "https://www.wireshark.org/download.html" | Out-Null
        }
        exit 1
    }
    Write-Ok "tshark found: $($tsharkCmd.Source)"

    $proc = Get-Process -Name $exeName -ErrorAction SilentlyContinue |
    Where-Object {
        if ($_.Path) {
            return ([string]::Equals([System.IO.Path]::GetFullPath($_.Path), $resolvedExe, [System.StringComparison]::OrdinalIgnoreCase))
        }
        return $true
    } |
    Select-Object -First 1

    if (-not $proc) {
        Write-Warn "Process is not running: $exeName"
        Write-Host "Start the app, then press Enter to continue..." -ForegroundColor Yellow
        [void](Read-Host)
        $proc = Get-Process -Name $exeName -ErrorAction SilentlyContinue | Select-Object -First 1
    }

    if (-not $proc) {
        Write-Err "Process still not found. Cancelled."
        exit 1
    }

    $pids = Get-ChildProcessIds -RootPid $proc.Id
    Write-Ok "Analyzing PIDs: $($pids -join ', ')"

    Write-Info "Capture starts now. Actively use the app during capture."

    $ports = New-Object "System.Collections.Generic.HashSet[string]" ([System.StringComparer]::OrdinalIgnoreCase)
    $remoteIps = New-Object "System.Collections.Generic.HashSet[string]" ([System.StringComparer]::OrdinalIgnoreCase)
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt $Duration) {
        try {
            $tcp = Get-NetTCPConnection -ErrorAction SilentlyContinue | Where-Object { $pids -contains $_.OwningProcess }
            foreach ($r in $tcp) {
                [void]$ports.Add("TCP:$($r.LocalPort)")
                if ($r.RemotePort -gt 0) { [void]$ports.Add("TCP-REMOTE:$($r.RemotePort)") }
                if ($r.RemoteAddress -and $r.RemoteAddress -match '^\d+\.\d+\.\d+\.\d+$') {
                    [void]$remoteIps.Add($r.RemoteAddress)
                }
            }
        }
        catch {}

        try {
            $udp = Get-NetUDPEndpoint -ErrorAction SilentlyContinue | Where-Object { $pids -contains $_.OwningProcess }
            foreach ($r in $udp) {
                [void]$ports.Add("UDP:$($r.LocalPort)")
            }
        }
        catch {}

        try {
            $netstatLines = netstat -ano -p tcp | Select-Object -Skip 4
            foreach ($line in $netstatLines) {
                $trim = "$line".Trim()
                if ([string]::IsNullOrWhiteSpace($trim)) { continue }
                $cols = $trim -split "\s+"
                if ($cols.Length -lt 5) { continue }
                $ownerPid = 0
                if (-not [int]::TryParse($cols[4], [ref]$ownerPid)) { continue }
                if ($pids -contains $ownerPid) {
                    $localParts = $cols[1] -split ":"
                    $remoteParts = $cols[2] -split ":"
                    $localPort = $localParts[-1]
                    $remotePort = $remoteParts[-1]
                    $remoteAddress = $remoteParts[0].Trim('[', ']')
                    if ($localPort -match "^\d+$") { [void]$ports.Add("NETSTAT-TCP:$localPort") }
                    if ($remotePort -match "^\d+$") { [void]$ports.Add("NETSTAT-TCP-REMOTE:$remotePort") }
                    if ($remoteAddress -match '^\d+\.\d+\.\d+\.\d+$') {
                        [void]$remoteIps.Add($remoteAddress)
                    }
                }
            }
        }
        catch {}

        Start-Sleep -Seconds 2
    }

    $dnsFilter = 'dns || _ws.col.Info contains "Standard query response" || _ws.col.Info contains "Standart query response"'
    $tsharkArgs = @(
        "-l",
        "-n",
        "-a", "duration:$Duration",
        "-f", "port 53",
        "-Y", $dnsFilter,
        "-T", "fields",
        "-E", "separator=`t",
        "-e", "frame.time",
        "-e", "ip.src",
        "-e", "ip.dst",
        "-e", "dns.qry.name",
        "-e", "dns.resp.name",
        "-e", "_ws.col.Info"
    )

    Write-Info "Running tshark for DNS on port 53..."
    $tsharkOutput = @()
    try {
        $tsharkOutput = & $tsharkCmd.Source @tsharkArgs 2>$null
    }
    catch {
        Write-Warn "tshark capture failed: $($_.Exception.Message)"
    }

    $domainSet = New-Object "System.Collections.Generic.HashSet[string]" ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($line in $tsharkOutput) {
        $parts = "$line" -split "`t", 6
        if ($parts.Length -ge 3) {
            foreach ($ipItem in @($parts[1], $parts[2])) {
                $cleanIp = "$ipItem".Trim()
                if ($cleanIp -match '^\d+\.\d+\.\d+\.\d+$') {
                    [void]$remoteIps.Add($cleanIp)
                }
            }
        }
        foreach ($d in (Read-DomainsFromTsharkLine -Line $line)) {
            [void]$domainSet.Add($d)
        }
    }

    $domains = @($domainSet | Sort-Object)
    $portRows = @($ports | Sort-Object)
    $ips = @($remoteIps | Sort-Object)

    Write-Host ""
    Write-Host "========================= RESULTS =========================" -ForegroundColor Cyan

    Write-Host ""
    Write-Host "Ports used by app (Get-NetTCPConnection/Get-NetUDPEndpoint + optional netstat):" -ForegroundColor White
    if ($portRows.Count -eq 0) {
        Write-Warn "No ports found for selected process during capture window"
    }
    else {
        foreach ($p in $portRows) {
            Write-Host "  $p" -ForegroundColor Green
        }
    }

    Write-Host ""
    Write-Host "DNS domains (captured on port 53 via tshark):" -ForegroundColor White
    if ($domains.Count -eq 0) {
        Write-Warn "No domains detected in DNS traffic"
    }
    else {
        foreach ($d in $domains) {
            Write-Host "  $d" -ForegroundColor Cyan
        }
    }

    Write-Host ""
    Write-Host "IP addresses (from app sockets and DNS capture):" -ForegroundColor White
    if ($ips.Count -eq 0) {
        Write-Warn "No IP addresses detected"
    }
    else {
        foreach ($ipRow in $ips) {
            Write-Host "  $ipRow" -ForegroundColor Magenta
        }
    }

    if ($domains.Count -eq 0 -and $ips.Count -eq 0) {
        exit 0
    }

    $targetList = Resolve-ListPath -UserPath $ListPath
    Initialize-ListFile -Path $targetList
    $targetIpset = Resolve-IpsetPath -UserPath $IpsetPath
    Initialize-IpsetFile -Path $targetIpset

    $existingLines = @(Get-Content -LiteralPath $targetList -ErrorAction SilentlyContinue)
    $existingSet = New-Object "System.Collections.Generic.HashSet[string]" ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($line in $existingLines) {
        $clean = "$line".Trim().ToLowerInvariant()
        if (-not [string]::IsNullOrWhiteSpace($clean)) {
            [void]$existingSet.Add($clean)
        }
    }

    $toAdd = @()
    foreach ($d in $domains) {
        if (-not $existingSet.Contains($d)) {
            $toAdd += $d
        }
    }

    $existingIpLines = @(Get-Content -LiteralPath $targetIpset -ErrorAction SilentlyContinue)
    $existingIpSet = New-Object "System.Collections.Generic.HashSet[string]" ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($line in $existingIpLines) {
        $cleanIp = "$line".Trim()
        if ($cleanIp -match '^\d+\.\d+\.\d+\.\d+/(32|24)$') {
            [void]$existingIpSet.Add($cleanIp)
        }
    }

    $ipsToAdd = @()
    foreach ($ipItem in $ips) {
        $cidr = "$ipItem/32"
        if (-not $existingIpSet.Contains($cidr)) {
            $ipsToAdd += $cidr
        }
    }

    Write-Host ""
    if ($toAdd.Count -eq 0 -and $ipsToAdd.Count -eq 0) {
        Write-Ok "All found domains and IP addresses already exist in target lists"
        exit 0
    }

    if ($toAdd.Count -gt 0) {
        Write-Host "Will be added to the top of list-general-user.txt:" -ForegroundColor Yellow
        foreach ($d in $toAdd) {
            Write-Host "  $d" -ForegroundColor Yellow
        }
    }

    if ($ipsToAdd.Count -gt 0) {
        Write-Host "Will be added to the top of ipset-all.txt:" -ForegroundColor Yellow
        foreach ($ipItem in $ipsToAdd) {
            Write-Host "  $ipItem" -ForegroundColor Yellow
        }
    }

    $answer = Read-Host "Add detected domains and IPs to lists? (Y/N, default: N)"
    if ($answer -notmatch "^(?i)y$") {
        Write-Warn "Skipped writing domains"
        exit 0
    }

    if ($toAdd.Count -gt 0) {
        $newBlock = ($toAdd -join "`r`n")
        $existingRaw = ""
        if (Test-Path -LiteralPath $targetList) {
            $existingRaw = Get-Content -LiteralPath $targetList -Raw -ErrorAction SilentlyContinue
        }

        $newContent = if ([string]::IsNullOrWhiteSpace($existingRaw)) {
            "$newBlock`r`n"
        }
        else {
            "$newBlock`r`n`r`n$existingRaw"
        }

        Set-Content -LiteralPath $targetList -Value $newContent -Encoding UTF8
        Write-Ok "Domains added to top of file: $targetList"
    }

    if ($ipsToAdd.Count -gt 0) {
        $ipBlock = ($ipsToAdd -join "`r`n")
        $existingIpRaw = ""
        if (Test-Path -LiteralPath $targetIpset) {
            $existingIpRaw = Get-Content -LiteralPath $targetIpset -Raw -ErrorAction SilentlyContinue
        }

        $newIpContent = if ([string]::IsNullOrWhiteSpace($existingIpRaw)) {
            "$ipBlock`r`n"
        }
        else {
            "$ipBlock`r`n`r`n$existingIpRaw"
        }

        Set-Content -LiteralPath $targetIpset -Value $newIpContent -Encoding UTF8
        Write-Ok "IP addresses added to top of file: $targetIpset"
    }
}

Main
