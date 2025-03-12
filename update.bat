@echo off
setlocal EnableDelayedExpansion
chcp 437 > nul

set "GITHUB_VERSION_URL=https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/main/.service/version.txt"
set "GITHUB_DOWNLOAD_URL=https://github.com/Flowseal/zapret-discord-youtube/releases/latest/download/zapret-discord-youtube-"

:: Required version is specified in first argument
set NEW_VERSION=%~1

if not defined NEW_VERSION (
    :: Check local file
    set "VERSION_FILE=check_updates.bat"
    if not exist "!VERSION_FILE!" (
        echo Error: file !VERSION_FILE! not found
        exit /b 1
    )

    :: Check local version
    for /f "tokens=2 delims==" %%A in ('findstr "LOCAL_VERSION=" "!VERSION_FILE!"') do set LOCAL_VERSION=%%A

    if not defined LOCAL_VERSION (
        for /f "tokens=2 delims==" %%A in ('findstr "CURRENT_VERSION=" "!VERSION_FILE!"') do set LOCAL_VERSION=%%A
    )

    set LOCAL_VERSION=!LOCAL_VERSION:"=!

    :: Get actual version
    for /f "delims=" %%A in ('powershell -command "(Invoke-WebRequest -Uri \"%GITHUB_VERSION_URL%\" -Headers @{\"Cache-Control\"=\"no-cache\"} -TimeoutSec 5).Content.Trim()" 2^>nul') do set "NEW_VERSION=%%A"

    if not defined NEW_VERSION (
        echo Error: Failed to fetch the latest version. Check your internet connection
        exit /b 1
    )

    :: Check actual version
    if "!LOCAL_VERSION!"=="!NEW_VERSION!" (
        echo You are using the latest version !LOCAL_VERSION!
        exit /b
    )

    :: Ask for confirmation of the update
    set /p "CHOICE=New version available !NEW_VERSION!, want to upgrade (Y/N)? "
    set "CHOICE=!CHOICE:~0,1!"
    
    if /i not "!CHOICE!"=="y" (
        echo Keeping local version
        exit /b
    )
)

:: Check archiver program
for /f "tokens=2*" %%A in ('reg query "HKLM\SOFTWARE\WinRAR" /v "exe32" 2^>nul') do set "ARCHIVER_PATH=%%B" & set "ARCH_EXT=rar"

if not defined ARCHIVER_PATH (
    for /f "tokens=2*" %%A in ('reg query "HKLM\SOFTWARE\7-Zip" /v Path 2^>nul') do set "ARCHIVER_PATH=%%B\7z.exe" & set "ARCH_EXT=zip"
)

if not defined ARCHIVER_PATH (
    echo Error: No archiver WinRAR or 7-Zip found
    exit /b 1
)

:: Restart with admin rights
NET SESSION >nul 2>&1
if not %ERRORLEVEL% == 0 (
    powershell -Command "Start-Process cmd -ArgumentList '/k cd /d %cd% && %~s0 %NEW_VERSION%' -Verb runAs"
    exit /b
)

:: Downloading arch file
set DOWNLOAD_URL=%GITHUB_DOWNLOAD_URL%%NEW_VERSION%.%ARCH_EXT%
set ARCHIVE_PATH=zapret-discord-youtube-%NEW_VERSION%.%ARCH_EXT%

echo Downloading %DOWNLOAD_URL%
curl -L "%DOWNLOAD_URL%" -o "%ARCHIVE_PATH%"

if not %ERRORLEVEL% == 0 (
    echo Error: Failed to download archive
    exit /b 1
)

:: Extract archive
set TMP_DIR=zapret-discord-youtube-%NEW_VERSION%
if not exist "%TMP_DIR%" mkdir "%TMP_DIR%"

if "%ARCH_EXT%"=="rar" (
    "%ARCHIVER_PATH%" x "%ARCHIVE_PATH%" "%TMP_DIR%" -y -inul -ibck
) else (
    "%ARCHIVER_PATH%" x "%ARCHIVE_PATH%" -o"%TMP_DIR%" -y -bso0 -bse0 -bsp0
)

if not %ERRORLEVEL% == 0 (
    echo Error: Failed to extract %ARCHIVE_PATH%
    exit /b 1
)

:: Removing WinDivert service
for /f "tokens=1 delims= " %%A in ('driverquery ^| find "Divert"') do set "DRIVER_NAME=%%A"
if defined DRIVER_NAME (
    sc stop "%DRIVER_NAME%" && sc delete "%DRIVER_NAME%"
)

:: Delete everything in current folder except script and extracted folder
set SCRIPT_NAME=%~nx0
for %%F in ("*") do if /I not "%%~nxF"=="%SCRIPT_NAME%" del /q "%%F"

for /f "delims=" %%A in ("%TMP_DIR%") do set "TMP_PATH=%%~fA"
for /d %%D in ("*") do if /I not "%%~fD"=="%TMP_PATH%" rd /s /q "%%D"

:: Copying the new version to the current destination
xcopy "%TMP_DIR%\*" "." /s /e /h /y >nul
if not %ERRORLEVEL% == 0 (
    echo Error: Failed to copy new version files
    exit /b 1
)

rd /s /q "%TMP_DIR%"
if not %ERRORLEVEL% == 0 (
    echo Error: Failed to delete temp folder %TMP_DIR%
    exit /b 1
)

echo The latest version has been successfully installed
endlocal
