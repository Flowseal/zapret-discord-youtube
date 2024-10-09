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
setlocal enabledelayedexpansion
set "cyrillic_found=0"
for /l %%i in (0,1,127) do (
    set "char=!scriptPath:~%%i,1!"
    for %%c in (А Б В Г Д Е Ё Ж З И Й К Л М Н О П Р С Т У Ф Х Ц Ч Ш Щ Ъ Ы Ь Э Ю Я а б в г д е ё ж з и й к л м н о п р с т у ф х ц ч ш щ ъ ы ь э ю я) do (
        if "!char!"=="%%c" set "cyrillic_found=1"
    )
)
:: This is only way what i found to check if cyrillic character is in string
:: If you know better way, please let me know

if %cyrillic_found% equ 1 (
    echo Путь содержит кириллицу. 
    echo Пожалуйста, переместите скрипт в директорию без кириллических символов.
    echo Кириллица - Русский алфавит.
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