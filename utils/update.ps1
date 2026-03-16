param(
    [string]$LocalVersion,
    [string]$Root
)

# Handle empty or invalid Root parameter
if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = Split-Path -Parent $PSCommandPath
    $Root = Split-Path -Parent $Root
}

# Clean up the path - remove quotes and trailing backslashes
$Root = $Root.Trim('"').Trim().TrimEnd('\')

# Validate and get full path
if (Test-Path $Root) {
    $Root = (Resolve-Path $Root).Path
} else {
    Write-Host "Error: Root path does not exist: $Root" -ForegroundColor Red
    exit 1
}

$VersionUrl = "https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/main/.service/version.txt"

$Temp = Join-Path $env:TEMP "zapret_update"
$Zip = Join-Path $Temp "update.zip"
$Log = Join-Path $Root "update.log"

New-Item -ItemType Directory -Force $Temp | Out-Null

"==== UPDATE $(Get-Date) ====" | Out-File -FilePath $Log -Append -Encoding UTF8

try {

    $Latest = (Invoke-WebRequest $VersionUrl -UseBasicParsing).Content.Trim()

    $ZipUrl = "https://github.com/Flowseal/zapret-discord-youtube/releases/download/$Latest/zapret-discord-youtube-$Latest.zip"

    Write-Host "Download URL:"
    Write-Host $ZipUrl

    if ($Latest -eq $LocalVersion) {

        Write-Host "Latest version installed" -ForegroundColor Green
        "No update needed" | Out-File -FilePath $Log -Append -Encoding UTF8
        exit
    }

    Write-Host "New version $Latest" -ForegroundColor Yellow

    Write-Host "Downloading zip..."
    Invoke-WebRequest $ZipUrl -OutFile $Zip

    Write-Host "Extracting..."
    Expand-Archive $Zip $Temp -Force

    $Updated = 0

    Get-ChildItem $Temp -Recurse | ForEach-Object {

        if ($_.PSIsContainer) { return }

        $rel = $_.FullName.Substring($Temp.Length + 1)
        $dst = Join-Path $Root $rel

        if (Test-Path $dst) {

            $h1 = (Get-FileHash $_.FullName).Hash
            $h2 = (Get-FileHash $dst).Hash

            if ($h1 -ne $h2) {

                Copy-Item $_.FullName $dst -Force

                Write-Host "Updated $rel"
                "Updated $rel" | Out-File -FilePath $Log -Append -Encoding UTF8

                $Updated++
            }

        }
        else {

            Copy-Item $_.FullName $dst -Force

            Write-Host "New $rel"
            "New $rel" | Out-File -FilePath $Log -Append -Encoding UTF8

            $Updated++
        }

    }

    Write-Host ""
    Write-Host "Updated files: $Updated" -ForegroundColor Green
    "Updated files: $Updated" | Out-File -FilePath $Log -Append -Encoding UTF8
    
    Write-Host ""
    Write-Host "Update completed. Please restart this script to use the new version." -ForegroundColor Yellow
    Write-Host "Press any key to close..." -ForegroundColor Yellow
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    
    # Find and kill parent cmd.exe process
    $parentPid = (Get-WmiObject Win32_Process -Filter "ProcessId=$PID").ParentProcessId
    Stop-Process -Id $parentPid -Force

}
catch {

    Write-Host "Update failed" -ForegroundColor Red
    Write-Host $_ -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red

    $_ | Out-File -FilePath $Log -Append -Encoding UTF8
    $_.Exception.Message | Out-File -FilePath $Log -Append -Encoding UTF8
    
    Write-Host ""
    Write-Host "Press any key to close..." -ForegroundColor Red
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    
    # Find and kill parent cmd.exe process
    $parentPid = (Get-WmiObject Win32_Process -Filter "ProcessId=$PID").ParentProcessId
    Stop-Process -Id $parentPid -Force

}