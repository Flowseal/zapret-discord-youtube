@echo off
chcp 65001 >nul
:: 65001 - UTF-8

net session >nul 2>&1

if not %errorLevel% == 0 (
   echo Started NOT as administrator. Press any key to start as administrator...
   pause >nul
   powershell -Command "Start-Process 'cmd.exe' -ArgumentList '/k \"\"%~f0\" admin\"' -Verb RunAs"
   exit /b
)

set SRVCNAME=zapret

net stop %SRVCNAME%
sc delete %SRVCNAME%

net stop "WinDivert"
sc delete "WinDivert"
net stop "WinDivert14"
sc delete "WinDivert14"
