# scan_dns.ps1 - Scans DNS cache for blocked domains and updates list-general-user.txt
param(
    [string]$ServiceChoice = "1,2,7",
    [string]$UserList = "..\lists\list-general-user.txt",
    [string]$ListsDir = "..\lists",
    [string]$LogFile = "scan_cache.log"
)

$choices = $ServiceChoice.Split(',') | ForEach-Object { $_ -replace '[^\d]','' } | Where-Object { $_ -ne '' } | Select-Object -Unique

$patterns = @()
if ($choices -contains '1') { $patterns += @('googlevideo','ggpht','ytimg','youtube','youtu.be','googleapis','gvt1','video','play.google.com') }
if ($choices -contains '2') { $patterns += @('discord','discordapp','discord.gg','discord.media') }
if ($choices -contains '3') { $patterns += @('telegram','t.me','web.telegram') }
if ($choices -contains '4') { $patterns += @('twitch','ttvnw','jtvnw','twitchcdn') }
if ($choices -contains '5') { $patterns += @('spotify','scdn','spotifycdn') }
if ($choices -contains '6') { $patterns += @('soundcloud','sndcdn') }
if ($choices -contains '7') { $patterns += @('roblox','rbxcdn','arkoselabs','rblx','rbx','robloxlabs','ro-blox','roblox-api') }
if ($choices -contains '8') { $patterns += @('twitter','x.com','twimg','reddit','redd.it','redditmedia','pinterest','pinimg','tiktok','tiktokcdn','bytedance','facebook','fbcdn','fb.com','fb.me','instagram','cdninstagram','instagram.feed','whatsapp','whatsapp.net','wa.me','snapchat','snapkit','viber') }
if ($choices -contains '9') { $patterns += @('epicgames','unrealengine','fortnite','battle.net','blizzard','ubisoft','ubi','origin','ea.com','minecraft','mojang','genshin','hoyoverse','mihoyo') }
if ($choices -contains '10') { $patterns += @('github','githubusercontent','stackoverflow','stackexchange','docker','docker.io','npmjs','npm') }
if ($choices -contains '11') { $patterns += @('cloudflareclient','warp') }
if ($choices -contains '12') { $patterns += @('googlevideo','ggpht','ytimg','youtube','youtu.be','googleapis','gvt1','video','play.google.com','discord','discordapp','discord.gg','discord.media','twitch','ttvnw','jtvnw','twitchcdn','spotify','scdn','spotifycdn','soundcloud','sndcdn','roblox','rbxcdn','arkoselabs','rblx','rbx','robloxlabs','ro-blox','roblox-api','twitter','x.com','twimg','reddit','redd.it','redditmedia','pinterest','pinimg','tiktok','tiktokcdn','bytedance','facebook','fbcdn','fb.com','fb.me','instagram','cdninstagram','instagram.feed','whatsapp','whatsapp.net','wa.me','snapchat','snapkit','viber','epicgames','unrealengine','fortnite','battle.net','blizzard','ubisoft','ubi','origin','ea.com','minecraft','mojang','genshin','hoyoverse','mihoyo','github','githubusercontent','stackoverflow','stackexchange','docker','docker.io','npmjs','npm','cloudflareclient','warp') }

$existing = @()
if (Test-Path $ListsDir) {
    $listFiles = Get-ChildItem -Path $ListsDir -Filter *.txt | Where-Object { $_.Name -notlike 'ipset-*' -and $_.Name -notlike '*-exclude-user.txt' }
    foreach ($file in $listFiles) {
        $existing += Get-Content $file.FullName | Where-Object { $_ -notmatch '^\s*#' } | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    }
    $existing = $existing | Select-Object -Unique
}

$candidates = @()
try {
    $cache = Get-DnsClientCache -ErrorAction SilentlyContinue
    if ($cache) {
        $candidates += $cache | Where-Object { $_.Name -match ($patterns -join '|') } | ForEach-Object { $_.Name }
    }
} catch {}

$added = 0
$newDomains = @()
$maxAddedDomains = 50
foreach ($domain in ($candidates | Select-Object -Unique | Select-Object -First $maxAddedDomains)) {
    # Skip if parent domain already exists in any list
    $parent = $domain -replace '^.*?([^.]+\.[^.]+)$', '$1'
    if ($parent -in $existing -or $domain -in $existing) {
        continue
    }
    $newDomains += $domain
    $added++
}

if ($added -gt 0) {
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm'
    $separator = '# ' + '='*65
    $separator | Add-Content -Path $UserList -Encoding UTF8
    "# Auto-detected on $timestamp" | Add-Content -Path $UserList -Encoding UTF8
    $separator | Add-Content -Path $UserList -Encoding UTF8
    $newDomains | Add-Content -Path $UserList -Encoding UTF8
    $logEntry = "$timestamp | Choice: $ServiceChoice | Added domains: $added"
    $logEntry | Add-Content -Path $LogFile -Encoding UTF8
    Write-Host "[+] Added $added new domain(s) to list-general-user.txt" -ForegroundColor Green
    Write-Host "    See log: utils\scan_cache.log" -ForegroundColor Gray
} else {
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm'
    $logEntry = "$timestamp | Choice: $ServiceChoice | No new domains"
    $logEntry | Add-Content -Path $LogFile -Encoding UTF8
    Write-Host "[*] No new domains found. Your list is up to date." -ForegroundColor Yellow
    Write-Host "    Tip: manually removed domains may still exist in other lists." -ForegroundColor Gray
}
