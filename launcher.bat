@echo off
:: zapret-discord-youtube — All-in-One Launcher.
:: Self-elevates via UAC, then opens the WPF GUI by default.
::   launcher.bat            -> WPF GUI (utils\launcher.gui.ps1)
::   launcher.bat cli        -> console TUI (utils\launcher.ps1)

setlocal

if "%~1"=="admin" goto run
if "%~1"=="admin-cli" goto runcli

if /I "%~1"=="cli" (
    powershell -NoProfile -Command "Start-Process 'cmd.exe' -ArgumentList '/c \"\"%~f0\" admin-cli\"' -Verb RunAs"
    exit /b
)

powershell -NoProfile -Command "Start-Process 'cmd.exe' -ArgumentList '/c \"\"%~f0\" admin\"' -Verb RunAs"
exit /b

:run
chcp 65001 > nul
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0utils\launcher.gui.ps1"
exit /b %errorlevel%

:runcli
chcp 65001 > nul
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0utils\launcher.ps1"
exit /b %errorlevel%
