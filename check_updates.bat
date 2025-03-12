@echo off
setlocal EnableDelayedExpansion
chcp 437 > nul

:: Set current version and URLs
set "LOCAL_VERSION=1.6.3"
set "GITHUB_VERSION_URL=https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/main/.service/version.txt"
set "GITHUB_RELEASE_URL=https://github.com/Flowseal/zapret-discord-youtube/releases/tag/"

:: Get the latest version from GitHub
for /f "delims=" %%A in ('powershell -command "(Invoke-WebRequest -Uri \"%GITHUB_VERSION_URL%\" -Headers @{\"Cache-Control\"=\"no-cache\"} -TimeoutSec 5).Content.Trim()" 2^>nul') do set "GITHUB_VERSION=%%A"

:: Error handling
if not defined GITHUB_VERSION (
    echo Error: Failed to fetch the latest version. Check your internet connection
    goto :EOF
)

:: Version comparison
if "%LOCAL_VERSION%"=="%GITHUB_VERSION%" (
    echo Latest version installed: %LOCAL_VERSION%
) else (
    echo New version available: %GITHUB_VERSION%
    echo Release page: %GITHUB_RELEASE_URL%%GITHUB_VERSION%
    
    set /p "CHOICE=Do you want to automatically upgrade to the new version? (y/n, default: y): "

    if "!CHOICE!"=="" set "CHOICE=y"

    if /i "!CHOICE!"=="y" (
        call "update.bat" "%GITHUB_VERSION%"
    )
)
if not "%1"=="soft" pause
endlocal
