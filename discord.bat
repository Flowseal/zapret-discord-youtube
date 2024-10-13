@echo off
chcp 65001 >nul
:: 65001 - UTF-8

cd /d "%~dp0"

set BIN=%~dp0bin\

start "zapret: discord" /min "%BIN%winws.exe" --wf-tcp=443 --wf-udp=443,50000-65535 ^
--filter-udp=443 --hostlist="list-discord.txt" --dpi-desync=fake --dpi-desync-repeats=6 --dpi-desync-udplen-increment=10 --dpi-desync-udplen-pattern=0xDEADBEEF --dpi-desync-fake-quic="%BIN%quic_initial_www_google_com.bin" --new ^
--filter-udp=50000-65535 --dpi-desync=fake --dpi-desync-any-protocol --dpi-desync-cutoff=d3 --dpi-desync-repeats=6 --dpi-desync-fake-quic="%BIN%quic_initial_www_google_com.bin" --new ^
--filter-tcp=443 --hostlist="list-discord.txt" --dpi-desync=fake,split --dpi-desync-autottl=2 --dpi-desync-repeats=6 --dpi-desync-fooling=badseq --dpi-desync-fake-tls="%BIN%tls_clienthello_www_google_com.bin"
