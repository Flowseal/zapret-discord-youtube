@echo off
:: zapret-discord-youtube — All-in-one Launcher
:: Wrapper that self-elevates and hands off to utils\launcher.ps1.

if "%1"=="admin" goto run

powershell -NoProfile -Command "Start-Process 'cmd.exe' -ArgumentList '/c \"\"%~f0\" admin\"' -Verb RunAs"
exit /b

:run
chcp 65001 > nul
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0utils\launcher.ps1"
exit /b %errorlevel%
