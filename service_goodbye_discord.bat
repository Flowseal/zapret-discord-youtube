@echo off
chcp 65001 >nul
:: 65001 - UTF-8

whoami /groups | findstr "S-1-16-12288" >nul && goto :admin
if "%~1"=="RunAsAdmin" goto :error

:error
echo.
echo. Данный файл должен быть запущен с правами администратора (ПКМ - Запустить от имени администратора).
echo. Чтобы выполнить создание сервиса.
echo.
goto :end

:admin


set BIN=%~dp0bin\
set ARGS=--wf-tcp=443 --wf-udp=443,50000-65535 ^
--filter-udp=443 --hostlist=\"%~dp0list-discord.txt\" --dpi-desync=fake --dpi-desync-udplen-increment=10 --dpi-desync-repeats=6 --dpi-desync-udplen-pattern=0xDEADBEEF --dpi-desync-fake-quic=\"%BIN%quic_initial_www_google_com.bin\" --new ^
--filter-udp=50000-65535 --dpi-desync=fake --dpi-desync-any-protocol --dpi-desync-fake-quic=\"%BIN%quic_initial_www_google_com.bin\" --new ^
--filter-tcp=443 --hostlist=\"%~dp0list-discord.txt\" --dpi-desync=fake,split2 --dpi-desync-autottl=2 --dpi-desync-fooling=md5sig --dpi-desync-fake-tls=\"%BIN%tls_clienthello_www_google_com.bin\"

set SRVCNAME=zapret

net stop %SRVCNAME%
sc delete %SRVCNAME%
sc create %SRVCNAME% binPath= "\"%BIN%winws.exe\" %ARGS%" DisplayName= "zapret DPI bypass : %SRVCNAME%" start= auto depend= "GoodbyeDPI"
sc description %SRVCNAME% "zapret DPI bypass software"
sc start %SRVCNAME%


:end
pause
exit /b
