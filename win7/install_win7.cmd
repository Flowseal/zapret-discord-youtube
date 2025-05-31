@echo off
chcp 65001 > nul
:: 65001 - UTF-8

cd /d "%~dp0"

if "%1"=="admin" (
    echo Started with admin rights
) else (
    echo Requesting admin rights...
    powershell -Command "Start-Process 'cmd.exe' -ArgumentList '/c \"\"%~f0\" admin\"' -Verb RunAs"
    exit /b
)

setlocal enabledelayedexpansion
if [%1] == [install] goto :install

if %PROCESSOR_ARCHITECTURE%==AMD64 (
 FOR /F "tokens=3" %%B IN ('reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v CurrentBuildNumber') do set BUILD=%%B
 if defined BUILD (
  goto :build
 ) else (
  echo Could not get the OS build number
 )
) else (
 echo The script only works on x64
)
goto :ex

:build
echo OS build number: %BUILD%
if NOT %BUILD%==7601 if NOT %BUILD%==7600 goto :dont
goto :eof

:dont
echo Only Windows 7 is supported
goto :ex

:install
sc stop windivert >nul 2>&1
sc delete windivert >nul 2>&1
copy WinDivert64.sys ..\bin
copy WinDivert.dll ..\bin
echo Ready

:ex
pause