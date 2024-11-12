@echo off
setlocal EnableDelayedExpansion
chcp 437 > nul

set "CURRENT_VERSION=1.6.1"
set "GITHUB_URL=https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/refs/heads/main/.service/version.txt"
set "RELEASE_URL=https://github.com/Flowseal/zapret-discord-youtube/releases"
set "VERSION_FILE=version.txt"
set "SKIP_VERSION=null"
set "FILE_EXISTS=1"

for /f "delims=" %%A in ('powershell -command "[datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss')"') do set CURRENT_TIMESTAMP=%%A

:: If file version.txt exists
if not exist %VERSION_FILE% (
    set "FILE_EXISTS=0"
    echo time: %CURRENT_TIMESTAMP%> %VERSION_FILE%
    echo ver: %CURRENT_VERSION%>> %VERSION_FILE%
)

:: Reading data from local version.txt
for /f "tokens=1,* delims=: " %%A in (%VERSION_FILE%) do (
    if "%%A"=="time" set "LAST_CHECK=%%B"
    if "%%A"=="ver" set "INSTALLED_VERSION=%%B"
    if "%%A"=="skip" set "SKIP_VERSION=%%B"
)

:: If file was called from thirdparty script (with 'soft' argument that blocks checking for 12 hours)
if "%~1"=="soft" (
    :: Converting dates to parts for calculation
    for /f "tokens=1-6 delims=-: " %%A in ("%CURRENT_TIMESTAMP%") do (
        set "CURRENT_MONTH=%%B"
        set "CURRENT_DAY=%%C"
        set "CURRENT_HOUR=%%D"
    )
    for /f "tokens=1-6 delims=-: " %%A in ("%LAST_CHECK%") do (
        set "LAST_MONTH=%%B"
        set "LAST_DAY=%%C"
        set "LAST_HOUR=%%D"
    )

    set /a "time_diff_in_minutes = (CURRENT_MONTH - LAST_MONTH) * 43200 + (CURRENT_DAY - LAST_DAY) * 1440 + (CURRENT_HOUR - LAST_HOUR) * 60"

    if !time_diff_in_minutes! LEQ 360 if !FILE_EXISTS!==1 (
        echo Skipping the update check because it hasnt been 6 hours
        goto :EOF
    )
)

:: Reading new version from github
set "NEW_VERSION="
for /f "delims=" %%A in ('powershell -command "(Invoke-WebRequest -Uri %GITHUB_URL% -Headers @{\"Cache-Control\"=\"no-cache\"} -TimeoutSec 5).Content" 2^>nul') do set "NEW_VERSION=%%A"
if not defined NEW_VERSION (
    echo Erorr reading new version
    goto :EOF
)

:: Rewrite file
echo time: %CURRENT_TIMESTAMP%> %VERSION_FILE%
echo ver: %INSTALLED_VERSION%>> %VERSION_FILE%
echo skip: %SKIP_VERSION%>> %VERSION_FILE%

:: Comparing versions
if "%NEW_VERSION%"=="%INSTALLED_VERSION%" (
    echo You are using the latest version %NEW_VERSION%.
    goto :EOF
) else (
    :: Check if version skipped
    if "%NEW_VERSION%"=="%SKIP_VERSION%" (
        echo Newer version %NEW_VERSION% skipped by user.
        goto :EOF
    ) else (
        echo New version found: %NEW_VERSION%.
        echo Visit %RELEASE_URL% to download a new version
    )
)

:: Skip check
set /p "CHOICE=Skip this update? (y/n, default: n): " || set "CHOICE=n"
set "CHOICE=!CHOICE:~0,1!"
if /i "!CHOICE!"=="y" (
    echo skip: %NEW_VERSION%>> %VERSION_FILE%
    echo Update %NEW_VERSION% skipped.
) else (
    start %RELEASE_URL%
)

endlocal
