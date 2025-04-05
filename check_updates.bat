@echo off
chcp 65001 > nul
setlocal enabledelayedexpansion

:: Check if the script is run with admin rights
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [INFO] This script is not running as Administrator. Restarting with elevated privileges...
    powershell -Command "Start-Process '%~dpnx0' -Verb runAs"
    exit /b
)

:: Configuration
set "MERGE_FILES=list-general.txt ipset-cloudflare.txt ipset-discord.txt list-discord.txt"
set "GITHUB_REPO=https://github.com/Flowseal/zapret-discord-youtube/releases/download"
set "GITHUB_VERSION_URL=https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/main/.service/version.txt"
set "LOCAL_DIR=%~dp0"
set "LOCAL_DIR=%LOCAL_DIR:~0,-1%"
set "TEMP_DIR=%TEMP%\zapret_update_%random%"
set "SCRIPT_NAME=%~nx0"

:: Check if SOFT_MODE is passed through "call check_updates.bat soft"
set "SOFT_MODE=0"
if "%~1"=="soft" (
    set "SOFT_MODE=1"
)

:: Function to print with timestamp
call :print "[INFO] Starting update process"

:: --- Stop services if running and not in soft mode ---
if "%SOFT_MODE%"=="0" (
    title Zapret Updater
    set "NEED_RESTART_SERVICE=0"
    setlocal enabledelayedexpansion
    set "ServiceState="

    for %%S in (zapret WinDivert) do (
        for /f "tokens=3 delims=: " %%A in ('sc query "%%S" ^| findstr /i "STATE"') do (
            set "ServiceState=%%A"
        )

        set "ServiceState=!ServiceState: =!"

        if /i "!ServiceState!"=="RUNNING" (
            call :print "[INFO] Service %%S is currently RUNNING, stopping temporarily..."
            net stop "%%S" >nul 2>&1 || (
                call :print "[ERROR] Failed to stop service %%S. Check the service name."
            )
            endlocal & set "NEED_RESTART_SERVICE=1" & setlocal enabledelayedexpansion
        ) else (
            call :print "[INFO] Service %%S is NOT running."
        )
    )
    endlocal
)

:: Check curl
where curl >nul 2>&1 || (
    call :print "[ERROR] curl not found. Install from: https://curl.se/"
    pause
    exit /b 1
)

:: Get the latest version from GitHub
call :print "[INFO] Fetching latest version from GitHub..."
for /f "delims=" %%A in ('curl -s "%GITHUB_VERSION_URL%"') do set "GITHUB_VERSION=%%A"
call :print "[INFO] Latest version: %GITHUB_VERSION%"

:: Build download URL for the zip file
set "DOWNLOAD_URL=%GITHUB_REPO%/%GITHUB_VERSION%/zapret-discord-youtube-%GITHUB_VERSION%.zip"

:: 1. Prepare temp directory
call :print "[1/4] Preparing temp directory..."
mkdir "%TEMP_DIR%" 2>nul || (
    call :print "[ERROR] Cannot create temp directory"
    pause
    exit /b 1
)

:: 2. Download the corresponding zip archive
call :print "[INFO] Downloading archive: %DOWNLOAD_URL%..."
curl -s -L -o "%TEMP_DIR%\zapret-discord-youtube-%GITHUB_VERSION%.zip" "%DOWNLOAD_URL%" || (
    call :print "[ERROR] Download failed."
    rmdir /s /q "%TEMP_DIR%" 2>nul
    pause
    exit /b 1
)

:: 3. Extract the ZIP file using PowerShell's Expand-Archive
call :print "[INFO] Extracting ZIP file..."
powershell -Command "$zipPath = '%TEMP_DIR%\zapret-discord-youtube-%GITHUB_VERSION%.zip'; $destPath = '%TEMP_DIR%'; Add-Type -AssemblyName System.IO.Compression.FileSystem; $encoding = [System.Text.Encoding]::GetEncoding('cp866'); [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $destPath, $encoding)"
if %errorlevel% neq 0 (
    call :print "[ERROR] Failed to extract ZIP file."
    rmdir /s /q "%TEMP_DIR%" 2>nul
    pause
    exit /b 1
)

:: 4. Copy files with exclusions
call :print "[3/4] Copying files..."
robocopy "%TEMP_DIR%" "%LOCAL_DIR%" /E /XC /XN /XO /NDL /NFL /NJH /NJS /NP ^
    /XD ".git" ".service" ^
    /XF "zapret-discord-youtube-%GITHUB_VERSION%.zip" ".gitignore" "LICENSE.txt" "README.md" "%SCRIPT_NAME%" >nul

:: 5. Merge special files
call :print "[4/4] Merging special files..."
for %%f in (%MERGE_FILES%) do (
    if exist "%TEMP_DIR%\%%f" (
        if exist "%LOCAL_DIR%\%%f" (
            call :print "[Merging] %%f"
            call :MergeFiles "%LOCAL_DIR%\%%f" "%TEMP_DIR%\%%f" "%LOCAL_DIR%\%%f"
        ) else (
            call :print "[Copying] %%f"
            copy "%TEMP_DIR%\%%f" "%LOCAL_DIR%\%%f"
        )
    )
)

:: Cleanup
rmdir /s /q "%TEMP_DIR%" 2>nul

:: Restart services if needed
if "%NEED_RESTART_SERVICE%"=="1" (
    call :print "[INFO] Restarting services..."
    net start "zapret" >nul 2>&1 || (
        call :print "[ERROR] Failed to start service zapret."
    )
)

:: No pause in SOFT_MODE
if "%SOFT_MODE%"=="0" (
    call :print "[SUCCESS] Update completed!"
    pause
)

exit /b 0

:: Merge function implementation 
:MergeFiles
setlocal disabledelayedexpansion
set "user_file=%~1"
set "new_file=%~2"
set "output_file=%~3"
set "temp_file=%TEMP%\%random%.tmp"

:: 1. Copy new file as base
if exist "%new_file%" (
    copy /y "%new_file%" "%temp_file%" >nul
    :: Ensure temp_file ends with newline
    for /f "delims=" %%l in ('type "%temp_file%"') do set "last_line=%%l"
    >>"%temp_file%" echo(
) else (
    call :print "[ERROR] Source file not found: %new_file%"
    endlocal
    goto :eof
)

:: 2. Add unique lines from user file
if exist "%user_file%" (
    setlocal enabledelayedexpansion
    for /f "tokens=* delims=" %%a in ('type "%user_file%"') do (
        set "line=%%a"
        if defined line (
            findstr /x /c:"!line!" "%temp_file%" >nul || >>"%temp_file%" echo(!line!
        )
    )
    endlocal
)

:: 3. Remove duplicates and empty lines
move /y "%temp_file%" "%output_file%" >nul

endlocal
goto :eof

:: Function to print log with timestamp
:print
    setlocal
    set "timestamp=%date% %time%"
    echo [%timestamp%] %~1
    endlocal
goto :eof
