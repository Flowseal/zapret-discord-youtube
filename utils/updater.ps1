param(
    [string]$VersionTag
)

$BaseDir = Split-Path (Split-Path $MyInvocation.MyCommand.Definition -Parent) -Parent
$TempPath = "$env:TEMP\zapret-discord-youtube.zip"


$answer = Read-Host "New version of zapret (${VersionTag}) available. Do you want to install it automatically? (Y/N) (Default: Y)"
if ($answer -eq 'N' -or $answer -eq 'n') {
    $answer = Read-Host "Remember this choice (disable checking for updates)? (Y/N) (Default: N)"
    if ($answer -eq 'Y' -or $answer -eq 'y') {
        Remove-Item -Path "${BaseDir}\utils\check_updates.enabled" -Force
        exit
    }
    exit
}

Write-Host "Updating zapret: $VersionTag"


$release = Invoke-RestMethod -Uri "https://api.github.com/repos/Flowseal/zapret-discord-youtube/releases/tags/${VersionTag}"

$asset = $release.assets | Where-Object { $_.name -like '*.zip' }

try {
    Invoke-WebRequest -Uri $asset.url `
    -Headers @{ Accept = "application/octet-stream" } `
    -OutFile $TempPath -ErrorAction Stop -UseBasicParsing
} catch {
    $msg = $_.Exception.Message
    Write-Host ("Something went wrong when update download. ${msg}")
    exit
}


Stop-Process -Name "winws" -Force -ErrorAction SilentlyContinue


try {
Expand-Archive $TempPath -DestinationPath $BaseDir -Force -ErrorAction SilentlyContinue
} catch{
$msg = $_.Exception.Message
Write-Host ("Something went wrong when update unpacking. Try again or update zapret manually ${msg}")
exit
}

Write-Host ("Zapret updated successfully. Recommended to restart the program or service ${msg}")
Start-Sleep -Seconds 10
