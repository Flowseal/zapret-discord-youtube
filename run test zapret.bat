@echo off
setlocal
chcp 65001 >nul

:: Check Admin rights
net session >nul 2>&1
if %errorLevel% == 0 (
    goto :run
) else (
    echo Requesting admin rights...
    goto :uac
)

:uac
    echo Set UAC = CreateObject^("Shell.Application"^) > "%temp%\getadmin.vbs"
    echo UAC.ShellExecute "%~s0", "", "", "runas", 1 >> "%temp%\getadmin.vbs"
    "%temp%\getadmin.vbs"
    del "%temp%\getadmin.vbs"
    exit /B

:run
    cd /d "%~dp0"
    
    echo Starting configuration tests...
    echo.
    powershell -NoProfile -ExecutionPolicy Bypass -File "test zapret.ps1"

    if %errorLevel% neq 0 (
        echo.
        echo Script execution error.
    )

    echo.
    pause
