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
    
    :: Check PowerShell
    where powershell >nul 2>&1
    if %errorLevel% neq 0 (
        echo PowerShell is not installed or not in PATH.
        echo Please install PowerShell and rerun this script.
        echo.
        pause
        exit /B 1
    )

    :: Require PowerShell 2.0+
    powershell -NoProfile -Command "if ($PSVersionTable -and $PSVersionTable.PSVersion -and $PSVersionTable.PSVersion.Major -ge 2) { exit 0 } else { exit 1 }" >nul 2>&1
    if %errorLevel% neq 0 (
        echo PowerShell 2.0 or newer is required.
        echo Please upgrade PowerShell and rerun this script.
        echo.
        pause
        exit /B 1
    )

    echo Starting configuration tests in PowerShell window...
    echo.
    start "" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0test zapret.ps1"
    exit /B
