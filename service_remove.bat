@echo off
chcp 65001 >nul
:: 65001 - UTF-8

:: Admin rights check
echo Данный файл должен быть запущен с правами администратора (ПКМ - Запустить от имени администратора).
echo Нажмите любую клавишу, чтобы продолжить удаление и остановку сервиса.
pause

set SRVCNAME=zapret

net stop %SRVCNAME%
sc delete %SRVCNAME%

pause
