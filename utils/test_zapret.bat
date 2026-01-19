@echo off
chcp 65001 > nul
cd /d %~dp0

: Check if script has run as admin
whoami /priv | find /i "SeChangeNotifyPrivilege                   Bypass traverse checking                                           Enabled" > nul 2> nul

: If script called without admin rights it returns errorlevel=1
if %errorlevel%==1 (
    powershell "start %0 -verb runas"
    exit /b
)

powershell -ExecutionPolicy Bypass -File "test zapret.ps1"
