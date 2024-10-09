@echo off
chcp 65001 >nul
:: 65001 - UTF-8

:: Path check
set scriptPath=%~dp0
set "path_no_spaces=%scriptPath: =%"
if not "%scriptPath%"=="%path_no_spaces%" (
    echo Путь содержит пробелы. 
    echo Пожалуйста, переместите скрипт в директорию без пробелов.
    pause
    exit /b
)

:: Admin rights check
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Скрипт запущен без прав администратора. 
    echo Запустите от имени администратора.
    pause
    exit /b
)

set SRVCNAME=zapret

net stop "%SRVCNAME%"
sc delete "%SRVCNAME%"

pause