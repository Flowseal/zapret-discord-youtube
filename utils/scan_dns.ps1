param(
    [string]$ServiceChoice,
    [string]$UserList = "..\lists\list-general-user.txt",
    [string]$ListsDir = "..\lists",
    [string]$LogFile = "scan_cache.log"
)

$choices = $ServiceChoice.Split(',') | % { $_ -replace '[^\d]','' } | ? { $_ -ne '' } | Select-Object -Unique
$valid = $choices | ? { $_ -in 1..12 }
if (-not $valid) {
    Write-Host "Invalid service choice. Use numbers 1-12." -ForegroundColor Red
    exit 2
}
$choices = $valid

$patterns = @()
if ($choices -contains '1') { $patterns += @('googlevideo','ggpht','ytimg','youtube','youtu.be','googleapis','gvt1','video','play.google.com') }
if ($choices -contains '2') { $patterns += @('discord','discordapp','discord.gg','discord.media') }
if ($choices -contains '4') { $patterns += @('twitch','ttvnw','jtvnw','twitchcdn') }
if ($choices -contains '5') { $patterns += @('spotify','scdn','spotifycdn') }
if ($choices -contains '6') { $patterns += @('soundcloud','sndcdn') }
if ($choices -contains '8') { $patterns += @('twitter','x.com','twimg','reddit','redd.it','redditmedia','pinterest','pinimg','tiktok','tiktokcdn','bytedance','facebook','fbcdn','fb.com','fb.me','instagram','cdninstagram','instagram.feed','whatsapp','whatsapp.net','wa.me','snapchat','snapkit','viber') }
if ($choices -contains '9') { $patterns += @('epicgames','unrealengine','fortnite','battle.net','blizzard','ubisoft','ubi','origin','ea.com','minecraft','mojang','genshin','hoyoverse','mihoyo') }
if ($choices -contains '10') { $patterns += @('github','githubusercontent','stackoverflow','stackexchange','docker','docker.io','npmjs','npm') }
if ($choices -contains '11') { $patterns += @('cloudflareclient','warp') }
if ($choices -contains '12') { $patterns += @('googlevideo','ggpht','ytimg','youtube','youtu.be','googleapis','gvt1','video','play.google.com','discord','discordapp','discord.gg','discord.media','twitch','ttvnw','jtvnw','twitchcdn','spotify','scdn','spotifycdn','soundcloud','sndcdn','twitter','x.com','twimg','reddit','redd.it','redditmedia','pinterest','pinimg','tiktok','tiktokcdn','bytedance','facebook','fbcdn','fb.com','fb.me','instagram','cdninstagram','instagram.feed','whatsapp','whatsapp.net','wa.me','snapchat','snapkit','viber','epicgames','unrealengine','fortnite','battle.net','blizzard','ubisoft','ubi','origin','ea.com','minecraft','mojang','genshin','hoyoverse','mihoyo','github','githubusercontent','stackoverflow','stackexchange','docker','docker.io','npmjs','npm','cloudflareclient','warp') }

$existing = @()
if (Test-Path $ListsDir) {
    $listFiles = Get-ChildItem -Path $ListsDir -Filter *.txt | ? { $_.Name -notlike 'ipset-*' -and $_.Name -notlike '*-exclude-user.txt' }
    foreach ($file in $listFiles) {
    $existing += Get-Content $file.FullName | ? { $_ -notmatch '^\s*#' } | % { $_.Trim() } | ? { $_ -ne '' }
    }
    $existing = $existing | Select-Object -Unique
}

$candidates = @()
try {
    $cache = Get-DnsClientCache -ErrorAction SilentlyContinue
    if ($cache) {
        $candidates += $cache | ? { $_.Name -match ($patterns -join '|') } | % { $_.Name }
        $candidates += $cache | ? { $_.Data -match ($patterns -join '|') } | % { $_.Data }
    }
} catch {}

$added = 0
$newDomains = @()

$currentEntryCount = 0
try {
    if (Test-Path $UserList) {
        $currentEntryCount = (Get-Content $UserList -Encoding UTF8 | ? { $_ -notmatch '^\s*#' -and $_.Trim() -ne '' }).Count
    }
} catch { $currentEntryCount = 0 }

if ($currentEntryCount -lt 200) {
    $maxAddedDomains = 200
} elseif ($currentEntryCount -lt 500) {
    $maxAddedDomains = 20
} else {
    $maxAddedDomains = 5
}

$ytPatterns = @('googlevideo','ggpht','ytimg','youtube','youtu.be','googleapis','gvt1','video','play.google.com','discord','discordapp','discord.gg','discord.media')
$ytCandidates = $candidates | Select-Object -Unique | ? { $_ -match ($ytPatterns -join '|') }
$otherCandidates = $candidates | Select-Object -Unique | ? { $_ -notmatch ($ytPatterns -join '|') }
$sortedCandidates = ($ytCandidates | Sort-Object { $_.Length } -Descending) + ($otherCandidates | Sort-Object { $_.Length } -Descending)

foreach ($domain in ($sortedCandidates | Select-Object -First $maxAddedDomains)) {
    if ($domain -notmatch '\.') { continue }
    if ($domain -match '^\d+\.\d+\.\d+\.\d+$') { continue }
    if ($domain.Length -le 5) { continue }
    if ($domain -match '\s|[^a-zA-Z0-9.\-]') { continue }
    if ($domain -in $existing) { continue }

    $parent = $domain -replace '^.*?([^.]+\.[^.]+)$', '$1'
    if ($parent -in $existing -and $parent -notmatch 'googlevideo|ggpht|ytimg') { continue }

    if ($choices -contains '12' -and $parent -notmatch 'googlevideo|ggpht|ytimg') {
        try {
            $reachable = Test-Connection -ComputerName $domain -Count 1 -Quiet -TimeoutSeconds 1
            if ($reachable) { continue }
        } catch { }
    }

    try {
        $dns = Resolve-DnsName -Name $domain -Type A -ErrorAction Stop
        if (-not $dns -or ($dns.IPAddress -eq '127.0.0.1')) { continue }
    } catch { continue }

    $newDomains += $domain
    $added++
}

if (Test-Path $UserList) {
    $lines = Get-Content $UserList -Encoding UTF8
    $cleaned = $lines | % {
        if ($_ -match '^\s*#') {
            $_
        } else {
            ($_.Trim() -split '\s+')[0]
        }
    }
    $cleaned | Set-Content $UserList -Encoding UTF8
    $lines = $cleaned

    $oldDomains = @()
    $inOldBlock = $false
    foreach ($line in $lines) {
        if ($line -match '^# =+') {
            $inOldBlock = -not $inOldBlock
            continue
        }
        if ($inOldBlock -and $line -notmatch '^\s*#' -and $line.Trim() -ne '') {
            $oldDomains += $line.Trim()
        }
    }

    if ($added -gt 0) {
        $newDomains = ($oldDomains + $newDomains) | Select-Object -Unique

        $newLines = @()
        $skip = $false
        foreach ($line in $lines) {
            if ($line -match '^# =+') {
                $skip = -not $skip
                continue
            }
            if (-not $skip) {
                $newLines += $line
            }
        }
        $newLines | Set-Content $UserList -Encoding UTF8

        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm'
        $separator = '# ' + '='*65
        Add-Content -Path $UserList -Value $separator -Encoding UTF8
        Add-Content -Path $UserList -Value "# Auto-detected on $timestamp" -Encoding UTF8
        Add-Content -Path $UserList -Value "# Services: $ServiceChoice" -Encoding UTF8
        foreach ($domain in $newDomains) {
            Add-Content -Path $UserList -Value $domain -Encoding UTF8
        }
        Add-Content -Path $UserList -Value $separator -Encoding UTF8

        $logEntry = "$timestamp | Choice: $ServiceChoice | Added domains: $added"
        Add-Content -Path $LogFile -Value $logEntry -Encoding UTF8
        Write-Host "[+] Added $added new domain(s) to list-general-user.txt" -ForegroundColor Green
        Write-Host "    See log: utils\scan_cache.log"
    } else {
        $logEntry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm') | Choice: $ServiceChoice | No new domains"
        Add-Content -Path $LogFile -Value $logEntry -Encoding UTF8
        Write-Host "[*] No new domains found. Your list is up to date." -ForegroundColor Yellow
    }
}
