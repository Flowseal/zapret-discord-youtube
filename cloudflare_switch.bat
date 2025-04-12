@echo off
chcp 65001 > nul
:: 65001 - UTF-8

:: Admin rights check
if "%1"=="admin" (
    echo Started with admin rights
) else (
    echo Requesting admin rights...
    powershell -Command "Start-Process 'cmd.exe' -ArgumentList '/c \"\"%~f0\" admin\"' -Verb RunAs"
    exit /b
)

set "LISTS=%~dp0lists\"
set "FILE=%LISTS%ipset-cloudflare.txt"

if not exist "%FILE%" (
    echo Error! ipset-cloudflare.txt not found, path: %FILE%
    goto :eof
)

findstr /C:"0.0.0.0" "%FILE%" >nul
if %ERRORLEVEL%==0 (
    echo Enabling cloudflare bypass...
    >"%FILE%" (
        echo 173.245.48.0/20
        echo 103.21.244.0/22
        echo 103.22.200.0/22
        echo 103.31.4.0/22
        echo 141.101.64.0/18
        echo 108.162.192.0/18
        echo 190.93.240.0/20
        echo 188.114.96.0/20
        echo 197.234.240.0/22
        echo 198.41.128.0/17
        echo 162.158.0.0/15
        echo 104.16.0.0/13
        echo 104.24.0.0/14
        echo 172.64.0.0/13
        echo 131.0.72.0/22
    )
) else (
    echo Disabling cloudflare bypass...
    >"%FILE%" (
        echo 0.0.0.0/32
    )
)

echo Done.
pause
