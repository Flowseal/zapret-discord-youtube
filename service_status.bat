@echo off
chcp 65001 > nul
:: 65001 - UTF-8

if "%~1"=="" (
    call :test_service zapret
    call :test_service WinDivert
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
        echo "%ServiceName%" is ALREADY RUNNING as service! Use "serivce_remove.bat" first if you want to run standalone bat.
        pause
    ) else (
        echo "%ServiceName%" service is RUNNING.
    )
) else if not "%~2"=="soft" (
    echo "%ServiceName%" is NOT running.
)

exit /b
