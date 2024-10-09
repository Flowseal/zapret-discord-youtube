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

:: Cyrillic check
echo %scriptPath% | findstr /r "[А-Яа-яЁё]" >nul
if %errorLevel% equ 0 (
    echo Путь содержит кирилицу. Пожалуйста, переместите скрипт в директорию без кириллических символов.
    echo Кириллица - Русский алфавит.
    pause
    exit /b
)

:: Admin rights check
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Запуск от имени администратора...
    powershell start -verb runas '%0'
    exit /b
)


set SRVCNAME=zapret

net stop "%SRVCNAME%"
sc delete "%SRVCNAME%"

echo Сервис остановлен и удален.
echo Если какой либо файл не удаляется, перезагрузите пк.
pause