@echo off
chcp 65001 > nul
setlocal EnableDelayedExpansion

:: Проверка аргумента
if "%~1"=="" (
    echo [ERROR] Не передан путь к параметрам. Пример: call profile_launcher.bat presets\winws-params-alt1.txt
    exit /b 1
)

:: Переход в корень
cd /d "%~dp0\.."

:: Пути
set "BIN=%~dp0..\bin\"
set "PARAMS=%~dp0..\%~1"

:: Проверка winws.exe и параметров
if not exist "%BIN%winws.exe" (
    echo [ERROR] winws.exe не найден!
    exit /b 1
)

if not exist "%PARAMS%" (
    echo [ERROR] Параметры %PARAMS% не найдены!
    exit /b 1
)

:: Проверка, не запущен ли уже winws.exe
tasklist /FI "IMAGENAME eq winws.exe" | find /I "winws.exe" > nul
if not errorlevel 1 (
    echo winws.exe уже работает.
    exit /b 0
)

:: Проверка службы и обновлений
call service\service_status.bat zapret
call updater\check_updates.bat soft

:: Получаем имя профиля из параметра
for %%F in ("%~1") do set "PROFILE_NAME=%%~nF"
set "PROFILE_NAME=!PROFILE_NAME:winws-params-=!"
set "PROFILE_NAME=!PROFILE_NAME:config-=!"
set "PROFILE_NAME=!PROFILE_NAME:.txt=!"
set "PROFILE_NAME=!PROFILE_NAME:-= !"

:: Запуск winws.exe с названием окна
start "zapret: !PROFILE_NAME!" /min "%BIN%winws.exe" @"%PARAMS%"

exit /b 0
