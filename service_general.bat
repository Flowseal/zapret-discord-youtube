@echo off
chcp 65001 >nul
:: 65001 - UTF-8

:: Admin rights check
echo Данный файл должен быть запущен с правами администратора (ПКМ - Запустить от имени администратора).
echo Нажмите любую клавишу, чтобы продолжить создание сервиса.
pause

set BIN=%~dp0bin\
set ARGS=--wf-tcp=80,443 --wf-udp=443,50000-65535 ^
--filter-udp=443 --hostlist=\"%~dp0list-general.txt\" --dpi-desync=fake --dpi-desync-repeats=6 --dpi-desync-udplen-increment=10 --dpi-desync-udplen-pattern=0xDEADBEEF --dpi-desync-fake-quic=\"%BIN%quic_initial_www_google_com.bin\" --new ^
--filter-udp=50000-65535 --dpi-desync=fake --dpi-desync-any-protocol --dpi-desync-cutoff=d3 --dpi-desync-repeats=6 --dpi-desync-fake-quic=\"%BIN%quic_initial_www_google_com.bin\" --new ^
--filter-tcp=80 --hostlist=\"%~dp0list-general.txt\" --dpi-desync=fake,split2 --dpi-desync-autottl=2 --dpi-desync-fooling=md5sig --new ^
--filter-tcp=443 --hostlist=\"%~dp0list-general.txt\" --dpi-desync=fake,split --dpi-desync-autottl=2 --dpi-desync-repeats=6 --dpi-desync-fooling=badseq --dpi-desync-fake-tls=\"%BIN%tls_clienthello_www_google_com.bin\"

set SRVCNAME=zapret

net stop %SRVCNAME%
sc delete %SRVCNAME%
sc create %SRVCNAME% binPath= "\"%BIN%winws.exe\" %ARGS%" DisplayName= "zapret DPI bypass : %SRVCNAME%" start= auto
sc description %SRVCNAME% "zapret DPI bypass software"
sc start %SRVCNAME%

pause
