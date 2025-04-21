@echo off
setlocal EnableDelayedExpansion
chcp 65001 > nul

:: Главные параметры
set "SRVCNAME=zapret"
set "BIN_PATH=%~dp0bin\"
set "LISTS_PATH=%~dp0lists\"

if "%~1"=="admin" (
    if "%~2"=="install" goto INSTALL_ADMIN
    if "%~2"=="remove" goto REMOVE_ADMIN
    if "%~2"=="status" goto STATUS_ADMIN
)

:MAIN_MENU
cls
echo.
echo  ==============================
echo     ZAPRET SERVICE MANAGER
echo  ==============================
echo  1. Установить сервис
echo  2. Удалить сервис
echo  3. Проверить статус
echo  4. Выход
echo  ==============================
echo.
choice /C 1234 /M "Выберите действие: "

if errorlevel 4 exit /b
if errorlevel 3 goto STATUS
if errorlevel 2 goto REMOVE
if errorlevel 1 goto INSTALL

:INSTALL
echo Запрос прав администратора...
powershell -Command "Start-Process 'cmd.exe' -ArgumentList '/c \"\"%~f0\" admin install\"' -Verb RunAs"
goto MAIN_MENU

:REMOVE
echo Запрос прав администратора...
powershell -Command "Start-Process 'cmd.exe' -ArgumentList '/c \"\"%~f0\" admin remove\"' -Verb RunAs"
goto MAIN_MENU

:STATUS
call :CHECK_STATUS
pause
goto MAIN_MENU

:INSTALL_ADMIN
cls
echo [УСТАНОВКА] Инициализация...
cd /d "%~dp0"

:: Проверка обновлений
if exist "check_updates.bat" (
    call check_updates.bat soft
) else (
    echo Файл check_updates.bat не найден!
    pause
)

:: Выбор конфигурации
echo.
echo Доступные конфигурации:
set "count=0"
for %%f in (*.bat) do (
    set "filename=%%~nxf"
    if /i not "!filename!"=="%~nx0" if /i not "!filename:~0,7!"=="service" if /i not "!filename:~0,13!"=="check_updates" (
        set /a count+=1
        echo !count!. %%f
        set "file!count!=%%f"
    )
)

:RETRY_CHOICE
set "choice="
set /p "choice=Введите номер конфигурации: "
if "!choice!"=="" goto RETRY_CHOICE

set "selectedFile=!file%choice%!"
if not exist "!selectedFile!" (
    echo Неверный выбор файла
    pause
    goto INSTALL_ADMIN
)

:: Парсинг аргументов как в оригинале
set "args="
set "capture=0"
for /f "usebackq tokens=*" %%a in ("!selectedFile!") do (
    set "line=%%a"
    if "!line!" neq "" (
        echo !line! | findstr /i /c:"!BIN_PATH!winws.exe" >nul
        if !errorlevel!==0 (
            set "args=!line:*winws.exe=!"
            set "args=!args:"=!"
            goto CREATE_SERVICE
        )
    )
)

:CREATE_SERVICE
echo Создание сервиса с параметрами: !args!

:: Удаляем старый сервис
net stop !SRVCNAME! >nul 2>&1
sc delete !SRVCNAME! >nul 2>&1

:: Создаем новый сервис
sc create !SRVCNAME! binPath= "\"!BIN_PATH!winws.exe\"!args!" DisplayName= "Zapret Service" start= auto
if !errorlevel! neq 0 (
    echo Ошибка создания сервиса!
    pause
    goto MAIN_MENU
)

sc description !SRVCNAME! "Zapret DPI bypass service" >nul
net start !SRVCNAME!

if !errorlevel!==0 (
    echo Сервис успешно запущен!
) else (
    echo Не удалось запустить сервис!
    sc query !SRVCNAME!
)
pause
goto MAIN_MENU

:REMOVE_ADMIN
cls
echo [УДАЛЕНИЕ] Остановка сервисов...
net stop !SRVCNAME! >nul 2>&1
sc delete !SRVCNAME! >nul
net stop WinDivert >nul 2>&1
sc delete WinDivert >nul
net stop WinDivert14 >nul 2>&1
sc delete WinDivert14 >nul
echo Все сервисы удалены!
pause
goto MAIN_MENU

:CHECK_STATUS
echo.
echo Текущий статус сервисов:
call :TEST_SERVICE !SRVCNAME!
call :TEST_SERVICE WinDivert
call :TEST_SERVICE WinDivert14
exit /b

:TEST_SERVICE
set "ServiceName=%~1"
set "status="
for /f "tokens=3 delims=: " %%A in ('sc query "!ServiceName!" ^| findstr /i "STATE" 2^>nul') do set "status=%%A"
if "!status: =!"=="RUNNING" (
    echo [✔] !ServiceName! - работает
) else (
    echo [✘] !ServiceName! - не активен
)
exit /b