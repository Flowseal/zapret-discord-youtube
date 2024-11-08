@echo off
chcp 65001 >nul
:: 65001 - UTF-8

set "arg=%1"
if "%arg%" == "admin" (
    echo Скрипт запущен с правами администратора
) else (
    powershell -Command "Start-Process -FilePath '%~f0' -ArgumentList 'admin' -Verb RunAs"
    exit /b
)

set SRVCNAME=zapret

net stop %SRVCNAME%
sc delete %SRVCNAME%

net stop "WinDivert"
sc delete "WinDivert"
net stop "WinDivert14"
sc delete "WinDivert14"

pause
