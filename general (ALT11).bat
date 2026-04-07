@echo off
chcp 65001 > nul
:: 65001 - UTF-8

set "BIN=%~dp0bin\"
set "LISTS=%~dp0lists\"
cd /d %BIN%

start "mczapret" /min "%BIN%winws.exe" --wf-tcp=25565 ^
--filter-tcp=25565 --ipset-exclude="%LISTS%ipset-exclude.txt" --dpi-desync-any-protocol=1 --dpi-desync-cutoff=n5 --dpi-desync=multisplit --dpi-desync-split-seqovl=582 --dpi-desync-split-pos=1 --dpi-desync-split-seqovl-pattern="%BIN%tls_clienthello_4pda_to.bin" --new ^
