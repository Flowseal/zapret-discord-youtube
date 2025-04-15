@echo off
chcp 65001 > nul
:: 65001 - UTF-8


cd /d "%~dp0"
call check_updates.bat soft
echo:

set BIN=%~dp0bin\
set LISTS=%~dp0lists\

start "loli-zapret: general" /min "%BIN%winws.exe" --wf-tcp=80,443 --wf-udp=443,50000-50100 ^
--filter-udp=443 --hostlist="%LISTS%list-general.txt" --dpi-desync=fake --dpi-desync-repeats=8 --dpi-desync-fake-quic="%BIN%quic_initial_www_google_com.bin" --new ^
--filter-udp=50000-50100 --dpi-desync=fake --dpi-desync-any-protocol --dpi-desync-cutoff=d4 --dpi-desync-repeats=8 --new ^
--filter-tcp=80 --hostlist="%LISTS%list-general.txt" --dpi-desync=fake,split2 --dpi-desync-autottl=3 --dpi-desync-fooling=md5sig --new ^
--filter-tcp=443 --hostlist="%LISTS%list-general.txt" --dpi-desync=fake --dpi-desync-ttl=4 --dpi-desync-fake-tls-mod=rnd,rndsni,padencap --new ^
--filter-udp=443 --dpi-desync=fake --dpi-desync-repeats=8 --dpi-desync-fake-quic="%BIN%quic_initial_www_google_com.bin" --new ^
--filter-tcp=80 --dpi-desync=fake,split2 --dpi-desync-autottl=3 --dpi-desync-fooling=md5sig --new ^
--filter-tcp=443 --dpi-desync=fake --dpi-desync-ttl=4 --dpi-desync-fake-tls-mod=rnd,rndsni,padencap