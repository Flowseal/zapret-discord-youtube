@echo off
chcp 65001 > nul
setlocal enabledelayedexpansion

:: Создаем временный файл для сортировки
:: Searching for .bat files in current folder, except files that start with "service"
echo Pick one of the options:
set "count=0"
for %%f in (*.bat) do (
    if /i not "%%~nxf"=="launcher.bat" (
        set "filename=%%~nxf"
            set /a count+=1
            echo !count!. %%f
            set "file!count!=%%f"
    )
)

:: Choosing file
:input
set "choice="
set /p "choice=Input file index (number): "
if "!choice!"=="" goto :eof

set "selectedFile=!file%choice%!"
if not defined selectedFile (
    echo Invalid choice, try again...
    goto input
)

:: Блок ввода номера
:input
echo.
set /p "choice=Введите номер файла (1-%count%): "
echo.

:: Проверка корректности ввода
set valid=0
for /l %%i in (1,1,%count%) do if "!choice!"=="%%i" set valid=1

if !valid! equ 0 (
    echo Ошибка: неверный номер. Введите число от 1 до %count%.
    goto input
)

:: Запуск выбранного файла
echo Запускаем файл: !file%choice%!
call "!file%choice%!"
