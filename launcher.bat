@echo off
:: codeDPI - All-in-One Launcher.
:: Backward-compatible alias of start.bat. Self-elevates via UAC, then opens
:: the minimal chooser by default.
::   launcher.bat            -> chooser (utils\launcher.chooser.ps1)
::   launcher.bat gui        -> full WPF launcher (utils\launcher.gui.ps1)
::   launcher.bat cli        -> console TUI (utils\launcher.ps1)
::
:: New top-level entry point: start.bat (same behavior).

setlocal EnableExtensions

if /I "%~1"=="admin"     goto run_chooser
if /I "%~1"=="admin-gui" goto run_gui
if /I "%~1"=="admin-cli" goto run_cli

set "ELEVATE_ARG=admin"
if /I "%~1"=="gui" set "ELEVATE_ARG=admin-gui"
if /I "%~1"=="cli" set "ELEVATE_ARG=admin-cli"

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "try { Start-Process -FilePath '%~f0' -ArgumentList '%ELEVATE_ARG%' -Verb RunAs -ErrorAction Stop } catch { Write-Host 'codeDPI: failed to launch elevated window:' $_.Exception.Message -ForegroundColor Red; Write-Host 'If a UAC prompt appeared and you clicked No, just retry and accept it.' -ForegroundColor Yellow; Write-Host ''; Write-Host 'Press ENTER to close this window...' -ForegroundColor DarkGray; [void][Console]::ReadLine(); exit 1 }"
set "ELEV_ERR=%ERRORLEVEL%"
if not "%ELEV_ERR%"=="0" (
    echo.
    echo codeDPI: elevation failed with code %ELEV_ERR%.
    pause
)
exit /b %ELEV_ERR%

:run_chooser
set "PS_FILE=%~dp0utils\launcher.chooser.ps1"
goto run_ps

:run_gui
set "PS_FILE=%~dp0utils\launcher.gui.ps1"
goto run_ps

:run_cli
set "PS_FILE=%~dp0utils\launcher.ps1"
goto run_ps

:run_ps
chcp 65001 > nul
cd /d "%~dp0"
title codeDPI
set "LAUNCHER_LOG=%~dp0launcher.log"
>>"%LAUNCHER_LOG%" echo [%DATE% %TIME%] starting "%PS_FILE%"

if not exist "%PS_FILE%" (
    echo.
    echo codeDPI: launcher script not found:
    echo   "%PS_FILE%"
    echo.
    echo Make sure you extracted the full archive (with the utils\ folder).
    >>"%LAUNCHER_LOG%" echo [%DATE% %TIME%] MISSING %PS_FILE%
    pause
    exit /b 2
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_FILE%"
set "PS_ERR=%ERRORLEVEL%"
>>"%LAUNCHER_LOG%" echo [%DATE% %TIME%] exit code %PS_ERR%

if not "%PS_ERR%"=="0" (
    echo.
    echo =====================================================================
    echo  codeDPI: PowerShell exited with code %PS_ERR%.
    echo  Script: %PS_FILE%
    echo  Log:    %LAUNCHER_LOG%
    echo =====================================================================
    echo.
    pause
)
exit /b %PS_ERR%
