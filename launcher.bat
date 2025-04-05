@echo off
chcp 65001 > nul
setlocal EnableDelayedExpansion

cd /d "%~dp0"

:menu
cls
echo ================================
echo         ZAPRET LAUNCHER
echo ================================
echo [1] Общий (General)
echo [2] MГTC
echo [3] MГTC2
echo [4] ALT1
echo [5] ALT2
echo [6] ALT3
echo [7] ALT4
echo [8] ALT5
echo [9] FAKE TLS MOD
echo [10] Discord Only
echo [0] Выход
echo.

set /p CHOICE=Выберите профиль: 

if "%CHOICE%"=="0" exit

:: Назначаем нужный пресет
if "%CHOICE%"=="1" set PARAMS=presets\winws-params-general.txt
if "%CHOICE%"=="2" set PARAMS=presets\winws-params-mgts.txt
if "%CHOICE%"=="3" set PARAMS=presets\winws-params-mgts2.txt
if "%CHOICE%"=="4" set PARAMS=presets\winws-params-alt.txt
if "%CHOICE%"=="5" set PARAMS=presets\winws-params-alt2.txt
if "%CHOICE%"=="6" set PARAMS=presets\winws-params-alt3.txt
if "%CHOICE%"=="7" set PARAMS=presets\winws-params-alt4.txt
if "%CHOICE%"=="8" set PARAMS=presets\winws-params-alt5.txt
if "%CHOICE%"=="9" set PARAMS=presets\winws-params-fake-tls.txt
if "%CHOICE%"=="10" set PARAMS=presets\winws-params-discord.txt

if not defined PARAMS (
    echo Неверный выбор.
    pause
    goto :menu
)

:: Запуск
call profiles\profile_launcher.bat "!PARAMS!"

endlocal
exit /b 0
