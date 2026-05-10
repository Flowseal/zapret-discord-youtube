@echo off
:: codeDPI — All-in-One Launcher.
:: Self-elevates via UAC, then opens the minimal chooser by default.
::   launcher.bat            -> chooser (utils\launcher.chooser.ps1)
::   launcher.bat gui        -> full WPF launcher (utils\launcher.gui.ps1)
::   launcher.bat cli        -> console TUI (utils\launcher.ps1)
::
:: New top-level entry point: start.bat (same behavior).

setlocal

if "%~1"=="admin"      goto run_chooser
if "%~1"=="admin-gui"  goto run_gui
if "%~1"=="admin-cli"  goto run_cli

if /I "%~1"=="gui" (
    powershell -NoProfile -Command "Start-Process 'cmd.exe' -ArgumentList '/c \"\"%~f0\" admin-gui\"' -Verb RunAs"
    exit /b
)
if /I "%~1"=="cli" (
    powershell -NoProfile -Command "Start-Process 'cmd.exe' -ArgumentList '/c \"\"%~f0\" admin-cli\"' -Verb RunAs"
    exit /b
)

powershell -NoProfile -Command "Start-Process 'cmd.exe' -ArgumentList '/c \"\"%~f0\" admin\"' -Verb RunAs"
exit /b

:run_chooser
chcp 65001 > nul
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0utils\launcher.chooser.ps1"
exit /b %errorlevel%

:run_gui
chcp 65001 > nul
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0utils\launcher.gui.ps1"
exit /b %errorlevel%

:run_cli
chcp 65001 > nul
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0utils\launcher.ps1"
exit /b %errorlevel%
