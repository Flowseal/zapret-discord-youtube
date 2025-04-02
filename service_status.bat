@echo off
chcp 65001 > nul
:: 65001 - UTF-8



if "%~1"=="" (
    echo "Services status check..."
    call :test_service zapret
    call :test_service WinDivert
    echo "Services status check complete!"
    pause
) else (
    echo "%~1 service status check check..."
    call :test_service "%~1" "soft"
    echo "%~1 service status check complete!"
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
