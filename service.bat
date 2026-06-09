@echo off
set "LOCAL_VERSION=1.9.9a"
set "SRVCNAME=zapret"
set "BIN_DIR=%~dp0bin\"
set "WINWS_EXE=%BIN_DIR%winws.exe"
set "LISTS_DIR=%~dp0lists\"
set "UTILS_DIR=%~dp0utils\"
set "TARGETS_FILE=%UTILS_DIR%targets.txt"
set "TEST_RESULTS_DIR=%UTILS_DIR%test results\"

setlocal EnableDelayedExpansion

:: Elevate script
FLTMNUR >nul 2>&1 || (
    echo Set UAC = CreateObject^("Shell.Application"^) > "%temp%\getadmin.vbs"
    echo sArgs = "" >> "%temp%\getadmin.vbs"
    echo For Each a In WScript.Arguments >> "%temp%\getadmin.vbs"
    echo sArgs = sArgs ^& " " ^& a >> "%temp%\getadmin.vbs"
    echo Next >> "%temp%\getadmin.vbs"
    echo oCustom = "%~f0" >> "%temp%\getadmin.vbs"
    echo oCustomArgs = sArgs >> "%temp%\getadmin.vbs"
    echo UAC.ShellExecute oCustom, oCustomArgs, "", "runas", 1 >> "%temp%\getadmin.vbs"
    "%temp%\getadmin.vbs"
    del "%temp%\getadmin.vbs"
    exit /b
)

title Zapret Service Manager v%LOCAL_VERSION%
cd /d "%~dp0"

:menu
cls
echo ======================================================
echo             Zapret Service Manager v%LOCAL_VERSION%
echo ======================================================
echo.
echo  [1] Install Service
echo  [2] Remove Service
echo  [3] Run Diagnostics / Run Tests
echo  [4] Switch IPSet Filter
echo  [5] Toggle Game Filter
echo  [6] Toggle Check Updates
echo  [7] Exit
echo.
echo ======================================================
echo.

set /p choice="Choose an option [1-7]: "

if "%choice%"=="1" goto service_install
if "%choice%"=="2" goto service_remove
if "%choice%"=="3" goto run_diagnostics
if "%choice%"=="4" goto switch_ipset
if "%choice%"=="5" goto toggle_game_filter
if "%choice%"=="6" goto toggle_check_updates
if "%choice%"=="7" exit
goto menu

:: INSTALL ====================================
:service_install
cls
echo Checking for existing service...
sc query %SRVCNAME% >nul 2>&1
if !errorlevel!==0 (
    echo Service '%SRVCNAME%' is already installed.
    echo Please remove it first using option [2].
    pause
    goto menu
)

echo.
echo Available strategies for service installation:
echo ------------------------------------------------------
echo  [1] General Strategy (Default)
echo  [2] ALT Strategy
echo  [3] ALT2 Strategy
echo  [4] ALT3 Strategy
echo  [5] ALT4 Strategy
echo  [6] ALT5 Strategy
echo  [7] ALT6 Strategy
echo  [8] ALT7 Strategy
echo  [9] ALT8 Strategy
echo  [10] ALT9 Strategy
echo  [11] ALT10 Strategy
echo  [12] ALT11 Strategy
echo  [13] ALT12 Strategy
echo  [14] FAKE TLS AUTO Strategy
echo  [15] FAKE TLS AUTO ALT Strategy
echo  [16] FAKE TLS AUTO ALT2 Strategy
echo  [17] FAKE TLS AUTO ALT3 Strategy
echo  [18] SIMPLE FAKE Strategy
echo  [19] SIMPLE FAKE ALT Strategy
echo  [20] SIMPLE FAKE ALT2 Strategy
echo ------------------------------------------------------
echo.

set /p strat="Select strategy [1-20]: "
set "STRAT_ARGS="

if "%strat%"=="1" set "STRAT_ARGS=--dpi-desync=split2 --dpi-desync-split-pos=2"
if "%strat%"=="2" set "STRAT_ARGS=--dpi-desync=split --dpi-desync-split-pos=2"
if "%strat%"=="3" set "STRAT_ARGS=--dpi-desync=disorder --dpi-desync-split-pos=2"
if "%strat%"=="4" set "STRAT_ARGS=--dpi-desync=fake --dpi-desync-split-pos=2"
if "%strat%"=="5" set "STRAT_ARGS=--dpi-desync=fake,split2 --dpi-desync-split-pos=2"
if "%strat%"=="6" set "STRAT_ARGS=--dpi-desync=fake,disorder --dpi-desync-split-pos=2"
if "%strat%"=="7" set "STRAT_ARGS=--dpi-desync=split2 --dpi-desync-fooling=md5sig"
if "%strat%"=="8" set "STRAT_ARGS=--dpi-desync=split2 --dpi-desync-fooling=badsum"
echo Creating service command line...

set "ARGS=--wf-tcp=80,443 --wf-udp=443 %STRAT_ARGS%"

if exist "%UTILS_DIR%game_filter.enabled" (
    set "ARGS=!ARGS! --wf-l3=ipv4 --wf-udp=10000-65535"
)

if exist "%LISTS_DIR%ipset-all.txt" (
    set "ARGS=!ARGS! --ipset=%LISTS_DIR%ipset-all.txt"
) else (
    set "ARGS=!ARGS! --hostlist=%LISTS_DIR%list-general.txt"
)

sc create %SRVCNAME% binPath= "\"%WINWS_EXE%\" %ARGS%" DisplayName= "Zapret DPI Bypass" start= auto >nul
if !errorlevel!==0 (
    sc description %SRVCNAME% "Automated DPI Bypass Service using winws" >nul
    net start %SRVCNAME%
    echo.
    echo Service installed and started successfully.
) else (
    echo.
    echo Failed to install service. Make sure you are running as administrator.
)
pause
goto menu

:: REMOVE =====================================
:service_remove
cls
echo Stopping service...
net stop %SRVCNAME% >nul 2>&1
echo Deleting service...
sc delete %SRVCNAME% >nul 2>&1

echo Cleaning up remaining WinDivert instances...
net stop "WinDivert" >nul 2>&1
sc query "WinDivert" >nul 2>&1
if !errorlevel!==0 (
    sc delete "WinDivert" >nul 2>&1
)
net stop "WinDivert14" >nul 2>&1
sc query "WinDivert14" >nul 2>&1
if !errorlevel!==0 (
    sc delete "WinDivert14" >nul 2>&1
)

:: Clean up old test results to keep the utils folder clean
if exist "%~dp0utils\test results\*.txt" del /f /q "%~dp0utils\test results\*.txt"

echo.
echo Service and drivers removed.
pause
goto menu

:: DIAGNOSTICS ================================
:run_diagnostics
cls
echo Running network and configuration diagnostics...
echo ------------------------------------------------------
if not exist "%WINWS_EXE%" echo ERROR: winws.exe missing in bin folder.
if not exist "%LISTS_DIR%list-general.txt" echo WARNING: list-general.txt missing.
if not exist "%TARGETS_FILE%" echo WARNING: targets.txt missing in utils.

echo.
echo Testing connectivity to major domains...
powershell -Command "try { Test-NetConnection -ComputerName youtube.com -Port 443 -InformationLevel Quiet } catch { $false }"
echo.
if exist "%UTILS_DIR%test zapret.ps1" (
    echo Launching advanced strategy tester...
    powershell -ExecutionPolicy Bypass -File "%UTILS_DIR%test zapret.ps1"
)
pause
goto menu

:: IPSET SWITCH ===============================
:switch_ipset
cls
echo Current mode:
if exist "%LISTS_DIR%ipset-all.txt" (
    echo [IPSet Mode Active] - Processing traffic via downloaded IPSet databases.
) else (
    echo [Hostlist Mode Active] - Processing traffic via clear text domain list.
)
echo.
echo  [1] Switch to IPSet Mode (Downloads ipset-all.txt)
echo  [2] Switch to Hostlist Mode (Uses list-general.txt)
echo.
set /p ipchoice="Select option: "
if "%ipchoice%"=="1" (
    echo Downloading database...
    if exist "%LISTS_DIR%ipset-all.txt" move /y "%LISTS_DIR%ipset-all.txt" "%LISTS_DIR%ipset-all.txt.backup" >nul
    curl -k -o "%LISTS_DIR%ipset-all.txt" "https://githubusercontent.com"
    if !errorlevel!==0 (
        echo IPSet database updated successfully.
    ) else (
        echo Failed to download IPSet. Restoring backup if exists.
        if exist "%LISTS_DIR%ipset-all.txt.backup" move /y "%LISTS_DIR%ipset-all.txt.backup" "%LISTS_DIR%ipset-all.txt" >nul
    )
)
if "%ipchoice%"=="2" (
    if exist "%LISTS_DIR%ipset-all.txt" del /f /q "%LISTS_DIR%ipset-all.txt"
    echo Switched to Hostlist mode.
)
echo Please reinstall the service (Option 2 then Option 1) to apply changes.
pause
goto menu

:: TOGGLE GAME FILTER =========================
:toggle_game_filter
cls
if exist "%UTILS_DIR%game_filter.enabled" (
    del /f /q "%UTILS_DIR%game_filter.enabled"
    echo Game Filter is now [DISABLED]. Game UDP traffic will bypass winws.
) else (
    echo enabled > "%UTILS_DIR%game_filter.enabled"
    echo Game Filter is now [ENABLED]. All UDP ports (10000-65535) will be scanned.
)
echo Please reinstall the service to apply changes.
pause
goto menu

:: TOGGLE CHECK UPDATES =======================
:toggle_check_updates
cls
if exist "%UTILS_DIR%check_updates.enabled" (
    del /f /q "%UTILS_DIR%check_updates.enabled"
    echo Auto update check at startup is now [DISABLED].
) else (
    echo enabled > "%UTILS_DIR%check_updates.enabled"
    echo Auto update check at startup is now [ENABLED].
)
pause
goto menu
