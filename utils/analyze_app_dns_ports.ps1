param(
    [Parameter(Mandatory = $true)]
    [string]$ExePath,

    [Parameter(Mandatory = $false)]
    [int]$Duration = 120,

    [Parameter(Mandatory = $false)]
    [string]$ListPath = "",

    [Parameter(Mandatory = $false)]
    [string]$IpsetPath = "",

    [Parameter(Mandatory = $false)]
    [string]$CaptureInterface = "",

    [Parameter(Mandatory = $false)]
    [string]$TsharkPath = ""
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

function Flush-DnsCacheSafe {
    Write-Info "Clearing DNS cache before app launch/capture..."

    try {
        if (Get-Command "Clear-DnsClientCache" -ErrorAction SilentlyContinue) {
            Clear-DnsClientCache -ErrorAction Stop
            Write-Ok "DNS cache cleared (Clear-DnsClientCache)."
            return
        }
    }
    catch {
        Write-Warn "Clear-DnsClientCache failed: $($_.Exception.Message)"
    }

    try {
        $null = & ipconfig /flushdns
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "DNS cache cleared (ipconfig /flushdns)."
        }
        else {
            Write-Warn "ipconfig /flushdns returned exit code $LASTEXITCODE"
        }
    }
    catch {
        Write-Warn "DNS cache flush failed: $($_.Exception.Message)"
    }
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

function Get-TargetProcess {
    param(
        [string]$ExeName,
        [string]$ResolvedExe
    )

    return Get-Process -Name $ExeName -ErrorAction SilentlyContinue |
    Where-Object {
        if ($_.Path) {
            return ([string]::Equals([System.IO.Path]::GetFullPath($_.Path), $ResolvedExe, [System.StringComparison]::OrdinalIgnoreCase))
        }
        return $true
    } |
    Select-Object -First 1
}

function Get-TsharkInterfaces {
    param([string]$TsharkPath)

    $items = @()
    try {
        $lines = & $TsharkPath -D 2>$null
        foreach ($line in $lines) {
            $text = "$line".Trim()
            if ($text -notmatch '^(\d+)\.\s+(.+)$') { continue }

            $idx = $Matches[1]
            $raw = $Matches[2]
            $name = $raw
            $desc = ""
            if ($raw -match '^(.*?)\s+\((.*)\)$') {
                $name = $Matches[1]
                $desc = $Matches[2]
            }

            $items += [PSCustomObject]@{
                Index       = [int]$idx
                Name        = $name
                Description = $desc
                Raw         = $raw
            }
        }
    }
    catch {
    }

    return @($items | Sort-Object Index)
}

function Resolve-TsharkCaptureInterface {
    param(
        [string]$UserInterface,
        [object[]]$TsharkInterfaces
    )

    if (-not [string]::IsNullOrWhiteSpace($UserInterface)) {
        return $UserInterface.Trim()
    }

    try {
        $defaultRoute = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Sort-Object RouteMetric, InterfaceMetric |
        Select-Object -First 1

        if (-not $defaultRoute) {
            return ""
        }

        $adapter = Get-NetAdapter -InterfaceIndex $defaultRoute.InterfaceIndex -ErrorAction SilentlyContinue |
        Select-Object -First 1

        if (-not $adapter -or -not $adapter.InterfaceGuid) {
            return ""
        }

        $guidValue = $adapter.InterfaceGuid.ToString().Trim('{}').ToUpperInvariant()
        $matched = $TsharkInterfaces |
        Where-Object {
            ("$($_.Raw)".ToUpperInvariant()) -match [regex]::Escape($guidValue)
        } |
        Select-Object -First 1

        if ($matched) {
            return "$($matched.Index)"
        }

        return ""
    }
    catch {
        return ""
    }
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

function Get-TimestampForFileName {
    return (Get-Date).ToString("yyyyMMdd_HHmmss")
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

    $tsharkExePath = ""
    if (-not [string]::IsNullOrWhiteSpace($TsharkPath)) {
        $tsharkExePath = [Environment]::ExpandEnvironmentVariables($TsharkPath.Trim().Trim('"'))
        $tsharkExePath = [System.IO.Path]::GetFullPath($tsharkExePath)

        if (-not (Test-Path -LiteralPath $tsharkExePath)) {
            Write-Err "Specified tshark.exe not found: $tsharkExePath"
            exit 1
        }
    }
    else {
        $tsharkCmd = Get-Command "tshark.exe" -ErrorAction SilentlyContinue
        if ($tsharkCmd) {
            $tsharkExePath = $tsharkCmd.Source
        }
    }

    if ([string]::IsNullOrWhiteSpace($tsharkExePath)) {
        Write-Err "tshark.exe not found in PATH"
        Write-Warn "tshark.exe usually located in the same folder as wireshark.exe"
        Write-Warn "Install Wireshark with TShark and add it to PATH, or pass -TsharkPath"
        Write-Host "Download: https://www.wireshark.org/download.html" -ForegroundColor Yellow
        $open = Read-Host "Open download page now? (Y/N, default: Y)"
        if ([string]::IsNullOrWhiteSpace($open) -or $open -match "^(?i)y$") {
            Start-Process "https://www.wireshark.org/download.html" | Out-Null
        }
        exit 1
    }
    Write-Ok "tshark found: $tsharkExePath"

    $tsharkInterfaces = Get-TsharkInterfaces -TsharkPath $tsharkExePath
    if ($tsharkInterfaces.Count -gt 0) {
        Write-Host ""
        Write-Host "Available tshark interfaces:" -ForegroundColor White
        foreach ($iface in $tsharkInterfaces) {
            if ([string]::IsNullOrWhiteSpace($iface.Description)) {
                Write-Host "  $($iface.Index). $($iface.Name)" -ForegroundColor Gray
            }
            else {
                Write-Host "  $($iface.Index). $($iface.Name) ($($iface.Description))" -ForegroundColor Gray
            }
        }
    }

    $autoInterface = Resolve-TsharkCaptureInterface -UserInterface $CaptureInterface -TsharkInterfaces $tsharkInterfaces
    if ([string]::IsNullOrWhiteSpace($CaptureInterface)) {
        $defaultHint = if ([string]::IsNullOrWhiteSpace($autoInterface)) { "tshark default" } else { $autoInterface }
        $manualSelection = Read-Host "Select tshark interface index/name (Enter = $defaultHint)"
        if (-not [string]::IsNullOrWhiteSpace($manualSelection)) {
            $autoInterface = $manualSelection.Trim()
        }
    }

    $tsharkInterface = $autoInterface
    if ([string]::IsNullOrWhiteSpace($tsharkInterface)) {
        Write-Warn "No explicit capture interface selected. tshark will use its default interface."
    }
    else {
        Write-Info "Using tshark interface: $tsharkInterface"
    }

    Flush-DnsCacheSafe

    $proc = Get-TargetProcess -ExeName $exeName -ResolvedExe $resolvedExe

    if (-not $proc) {
        Write-Warn "Process is not running: $exeName"

        Write-Info "Trying to start the application automatically..."
        try {
            $started = Start-Process -FilePath $resolvedExe -PassThru -ErrorAction Stop
            Write-Ok "Launch command sent (PID: $($started.Id)). Waiting for process..."
        }
        catch {
            Write-Err "Failed to start app: $($_.Exception.Message)"
            Write-Err "Please start the app manually and run analyzer again."
            exit 1
        }

        $deadline = (Get-Date).AddSeconds(30)
        do {
            Start-Sleep -Seconds 1
            $proc = Get-TargetProcess -ExeName $exeName -ResolvedExe $resolvedExe
        }
        until ($proc -or (Get-Date) -ge $deadline)
    }

    if (-not $proc) {
        Write-Err "Process still not found after auto-start attempt. Cancelled."
        exit 1
    }

    Write-Ok "Process is running: PID $($proc.Id)"

    $pids = Get-ChildProcessIds -RootPid $proc.Id
    Write-Ok "Analyzing PIDs: $($pids -join ', ')"

    Write-Info "Capture starts now. Actively use the app during capture."

    Write-Info "Collecting ports and DNS in parallel..."
    $tempPcap = Join-Path $env:TEMP ("zapret_dns_{0}.pcapng" -f (Get-TimestampForFileName))
    $tsharkCaptureJob = $null
    try {
        $tsharkCaptureJob = Start-Job -ArgumentList @($tsharkExePath, $Duration, $tempPcap, $tsharkInterface) -ScriptBlock {
            param($tsharkPath, $durationValue, $pcapPath, $ifaceValue)

            $captureArgs = @(
                "-n",
                "-a", "duration:$durationValue",
                "-w", $pcapPath
            )

            if (-not [string]::IsNullOrWhiteSpace($ifaceValue)) {
                $captureArgs = @("-i", $ifaceValue) + $captureArgs
            }

            $captureText = & $tsharkPath @captureArgs 2>&1
            [PSCustomObject]@{
                ExitCode = $LASTEXITCODE
                Output   = @($captureText)
            }
        }
    }
    catch {
        Write-Err "Failed to capture traffic: $($_.Exception.Message)"
        if (Test-Path -LiteralPath $tempPcap) {
            Remove-Item -LiteralPath $tempPcap -Force -ErrorAction SilentlyContinue
        }
        exit 1
    }

    $remoteIps = New-Object "System.Collections.Generic.HashSet[string]" ([System.StringComparer]::OrdinalIgnoreCase)
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt $Duration) {
        try {
            $tcp = Get-NetTCPConnection -ErrorAction SilentlyContinue | Where-Object { $pids -contains $_.OwningProcess }
            foreach ($r in $tcp) {
                if ($r.RemoteAddress -and $r.RemoteAddress -match '^\d+\.\d+\.\d+\.\d+$') {
                    [void]$remoteIps.Add($r.RemoteAddress)
                }
            }
        }
        catch {}

        Start-Sleep -Seconds 2
    }

    $tsharkOutput = @()
    $dnsPacketCount = 0
    try {
        if (-not $tsharkCaptureJob) {
            throw "tshark capture job was not started"
        }

        Wait-Job -Job $tsharkCaptureJob | Out-Null
        $captureResult = Receive-Job -Job $tsharkCaptureJob -ErrorAction SilentlyContinue
        $captureExitCode = ($captureResult | Select-Object -First 1).ExitCode
        if ($captureExitCode -ne 0) {
            $captureSample = (($captureResult | Select-Object -First 1).Output | Select-Object -First 5) -join "`n"
            if (-not [string]::IsNullOrWhiteSpace($captureSample)) {
                Write-Err "$captureSample"
            }
            throw "tshark capture failed with exit code $captureExitCode"
        }

        if (-not (Test-Path -LiteralPath $tempPcap)) {
            throw "Capture file not found: $tempPcap"
        }

        $countArgs = @(
            "-n",
            "-r", $tempPcap,
            "-Y", "dns",
            "-T", "fields",
            "-e", "frame.number"
        )
        $dnsCountLines = @(& $tsharkExePath @countArgs 2>$null)
        $dnsPacketCount = $dnsCountLines.Count

        $parseArgs = @(
            "-n",
            "-r", $tempPcap,
            "-Y", "dns",
            "-T", "fields",
            "-E", "separator=`t",
            "-e", "frame.time",
            "-e", "ip.src",
            "-e", "ip.dst",
            "-e", "dns.qry.name",
            "-e", "dns.resp.name",
            "-e", "_ws.col.Info"
        )

        $tsharkOutput = @(& $tsharkExePath @parseArgs 2>&1)
    }
    catch {
        Write-Warn "tshark parse failed: $($_.Exception.Message)"
    }
    finally {
        if ($tsharkCaptureJob) {
            Remove-Job -Job $tsharkCaptureJob -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $tempPcap) {
            Remove-Item -LiteralPath $tempPcap -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Info "DNS packets in capture: $dnsPacketCount"

    $domainSet = New-Object "System.Collections.Generic.HashSet[string]" ([System.StringComparer]::OrdinalIgnoreCase)
    $dnsRowsCount = 0
    foreach ($line in $tsharkOutput) {
        $parts = "$line" -split "`t", 6
        if ($parts.Length -ge 3) {
            $dnsRowsCount++
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

    if ($dnsRowsCount -eq 0) {
        Write-Warn "No parseable DNS rows were returned by tshark."
        $diagLines = @($tsharkOutput | Select-Object -First 5)
        if ($diagLines.Count -gt 0) {
            Write-Host "tshark output sample:" -ForegroundColor Yellow
            foreach ($diag in $diagLines) {
                Write-Host "  $diag" -ForegroundColor Yellow
            }
        }
    }

    $domains = @($domainSet | Sort-Object)
    $ips = @($remoteIps | Sort-Object)

    Write-Host ""
    Write-Host "========================= RESULTS =========================" -ForegroundColor Cyan

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
