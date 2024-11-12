@echo off
chcp 65001 >nul
:: 65001 - UTF-8

set "arg=%1"
if "%arg%" == "admin" (
    echo Restarted with admin rights
) else (
    powershell -Command "Start-Process 'cmd.exe' -ArgumentList '/k \"\"%~f0\" admin\"' -Verb RunAs"
    exit /b
)

call check_updates.bat soft
echo:

set BIN=%~dp0bin\
set ARGS=--wf-tcp=443 --wf-udp=443,50000-50100 ^
--filter-udp=443 --hostlist=\"%~dp0list-discord.txt\" --dpi-desync=fake --dpi-desync-repeats=6 --dpi-desync-fake-quic=\"%BIN%quic_initial_www_google_com.bin\" --new ^
--filter-udp=50000-50100 --ipset=\"%~dp0ipset-discord.txt\" --dpi-desync=fake --dpi-desync-any-protocol --dpi-desync-cutoff=d3 --dpi-desync-repeats=6 --new ^
--filter-tcp=443 --hostlist=\"%~dp0list-discord.txt\" --dpi-desync=fake,split --dpi-desync-autottl=2 --dpi-desync-repeats=6 --dpi-desync-fooling=badseq --dpi-desync-fake-tls=\"%BIN%tls_clienthello_www_google_com.bin\"

set SRVCNAME=zapret

net stop %SRVCNAME%
sc delete %SRVCNAME%
sc create %SRVCNAME% binPath= "\"%BIN%winws.exe\" %ARGS%" DisplayName= "zapret DPI bypass : %SRVCNAME%" start= auto depend= "GoodbyeDPI"
sc description %SRVCNAME% "zapret DPI bypass software"
sc start %SRVCNAME%
