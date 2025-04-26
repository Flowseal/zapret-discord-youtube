@echo off
setlocal EnableDelayedExpansion
chcp 65001 > nul
:: 65001 - UTF-8

if "%~1"=="" (
    echo Checking services and tasks...
    call :test_service zapret
    call :test_service WinDivert
    tasklist /FI "IMAGENAME eq winws.exe" | find /I "winws.exe" > nul
    if !errorlevel!==0 (
        echo Bypass is ACTIVE
    ) else (
        echo Bypass NOT FOUND
    )
    pause
) else (
    call :test_service "%~1" "soft"
)

exit /b

:test_service
set "ServiceName=%~1"
set "ServiceStatus="

for /f "tokens=3 delims=: " %%A in ('sc query "%ServiceName%" ^| findstr /i "STATE"') do set "ServiceStatus=%%A"

set "ServiceStatus=%ServiceStatus: =%"

if "%ServiceStatus%"=="RUNNING" (
    if "%~2"=="soft" (
        echo "%ServiceName%" is ALREADY RUNNING as service, use "service_remove.bat" first if you want to run standalone bat.
        pause
    ) else (
        echo "%ServiceName%" service is RUNNING.
    )
) else if not "%~2"=="soft" (
    echo "%ServiceName%" is NOT running.
)

exit /b
