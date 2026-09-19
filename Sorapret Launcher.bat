@echo off
setlocal EnableExtensions EnableDelayedExpansion
chcp 65001 >nul
cd /d "%~dp0"

title Sorapret Launcher

:: Request administrator rights once for WinDivert/winws.
fltmc >nul 2>&1
if errorlevel 1 if /i not "%~1"=="admin" (
    echo Запрашиваются права администратора...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%ComSpec%' -ArgumentList '/c ""%~f0" admin' -Verb RunAs"
    exit /b
)

:menu
cls
echo.
echo  ==================================================
echo           SORAPRET LAUNCHER
echo  Быстрый запуск стратегий обхода для Discord
echo  ==================================================
echo.
echo  Стратегии:

set "count=0"
for /f "delims=" %%F in ('dir /b /a-d "Sorapret*.bat" 2^>nul ^| findstr /v /i /b /c:"Sorapret Launcher.bat"') do (
    set /a count+=1
    set "strategy!count!=%%F"
    echo    !count!. %%F
)

if !count! EQU 0 (
    echo    Стратегии Sorapret не найдены.
    echo.
    pause
    goto :eof
)

echo.
echo    M. Открыть менеджер служб
echo    0. Выход
echo.
set "choice="
set /p "choice=  Выберите стратегию: "

if /i "!choice!"=="0" exit /b
if /i "!choice!"=="M" (
    call "%~dp0service.bat"
    goto menu
)

set "selected="
for /l %%N in (1,1,!count!) do if "!choice!"=="%%N" set "selected=!strategy%%N!"

if not defined selected (
    echo.
    echo  Неверный выбор.
    timeout /t 2 /nobreak >nul
    goto menu
)

echo.
echo  Подготовка и запуск: !selected!
echo  При первом запуске создаётся bin\winws-sorapret.exe с новой иконкой.
echo  Оригинальный bin\winws.exe остаётся без изменений.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0utils\run-sorapret-strategy.ps1" -Strategy "!selected!"
if errorlevel 1 (
    echo.
    echo  Не удалось подготовить или запустить стратегию.
    echo  Проверьте сообщения PowerShell выше.
)
echo.
pause
goto menu
