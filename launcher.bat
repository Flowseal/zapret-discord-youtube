@echo off
chcp 65001 > nul
setlocal enabledelayedexpansion

:: Создаем временный файл для сортировки
set "tempfile=%temp%\%~n0_temp.txt"
if exist "%tempfile%" del "%tempfile%"

:: Счетчик файлов
set count=0

:: Собираем файлы с приоритетной сортировкой
for %%f in (*.bat) do (
    if /i not "%%~nxf"=="launcher.bat" (
        set "name=%%f"
        set "sortkey=5_%%f"  :: По умолчанию - группа 5
        
        :: Определяем приоритетные группы
        if /i "!name!"=="general.bat" set "sortkey=1_!name!"
        if /i "!name!" neq "general.bat" (
            echo "!name!" | findstr /i /c:"general (ALT" >nul && set "sortkey=2_!name!"
            echo "!name!" | findstr /i /c:"general (МГТС" >nul && set "sortkey=3_!name!"
            if "!sortkey:~0,1!"=="5" (
                echo "!name!" | findstr /i "general" >nul && set "sortkey=4_!name!"
            )
        )
        
        :: Записываем во временный файл
        echo !sortkey!>>"%tempfile%"
    )
)

:: Проверяем наличие файлов
if not exist "%tempfile%" (
    echo В директории нет других BAT-файлов.
    pause
    exit /b
)

:: Сортируем и выводим список
for /f "tokens=1* delims=_" %%a in ('sort "%tempfile%"') do (
    set /a count+=1
    set "file!count!=%%b"
    echo [!count!] %%b
)

:: Удаляем временный файл
del "%tempfile%" >nul 2>&1

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
