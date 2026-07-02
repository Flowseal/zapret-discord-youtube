@echo off
chcp 65001 > nul
:: 65001 - UTF-8
:: MarStart Gaming Edition - CS2 + Faceit EU (STRICT DPI / HARD MODE)
:: Optimized for: Aggressive DPI (QUIC drops, TCP resets)
:: Techniques: fake, disorder, split2, badseq

cd /d "%~dp0"
call service.bat status_zapret
call service.bat check_updates
call service.bat load_game_filter
call service.bat load_user_lists
echo:

set "BIN=%~dp0bin\"
set "LISTS=%~dp0lists\"
cd /d %BIN%

echo ============================================
echo   MarStart Gaming Edition (STRICT DPI)
echo   CS2 + Faceit EU Servers - Hard Mode
echo   Optimized for: Aggressive DPI Bypass
echo ============================================
echo:

start "zapret: %~n0" /min "%BIN%winws.exe" --wf-tcp=80,443,27015-27050,%GameFilterTCP% --wf-udp=443,27000-27100,3478-3480,4379-4380,%GameFilterUDP% ^
--filter-udp=27000-27014,27051-27100 --dpi-desync=fake,disorder --dpi-desync-ttl=autottl --dpi-desync-repeats=6 --dpi-desync-fake-unknown-udp="%BIN%quic_initial_4pda.to.bin" --new ^
--filter-udp=443 --hostlist="%LISTS%list-gaming-steam-sdr.txt" --hostlist-exclude="%LISTS%list-exclude.txt" --hostlist-exclude="%LISTS%list-exclude-user.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --dpi-desync=fake,disorder --dpi-desync-ttl=autottl --dpi-desync-fooling=badseq --dpi-desync-repeats=6 --dpi-desync-fake-quic="%BIN%quic_initial_4pda.to.bin" --new ^
--filter-udp=27015-27050 --filter-l7=stun --dpi-desync=fake,disorder --dpi-desync-ttl=autottl --dpi-desync-repeats=6 --dpi-desync-fake-unknown-udp="%BIN%quic_initial_4pda.to.bin" --new ^
--filter-udp=3478-3480 --dpi-desync=fake,disorder --dpi-desync-ttl=autottl --dpi-desync-repeats=6 --dpi-desync-fake-unknown-udp="%BIN%quic_initial_4pda.to.bin" --new ^
--filter-udp=4379-4380 --dpi-desync=fake,disorder --dpi-desync-ttl=autottl --dpi-desync-repeats=6 --dpi-desync-fake-unknown-udp="%BIN%quic_initial_4pda.to.bin" --new ^
--filter-tcp=443 --hostlist="%LISTS%list-gaming.txt" --hostlist-exclude="%LISTS%list-exclude.txt" --hostlist-exclude="%LISTS%list-exclude-user.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --dpi-desync=fake,disorder --dpi-desync-ttl=autottl --dpi-desync-fooling=badseq --dpi-desync-repeats=6 --dpi-desync-fake-tls="%BIN%tls_clienthello_www_google_com.bin" --dpi-desync-cutoff=n4 --new ^
--filter-tcp=80 --hostlist="%LISTS%list-gaming.txt" --hostlist-exclude="%LISTS%list-exclude.txt" --hostlist-exclude="%LISTS%list-exclude-user.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --dpi-desync=fake,disorder --dpi-desync-ttl=autottl --dpi-desync-fooling=badseq --dpi-desync-repeats=4 --dpi-desync-fake-http="%BIN%tls_clienthello_max_ru.bin" --dpi-desync-cutoff=n4 --new ^
--filter-tcp=443,80 --ipset="%LISTS%ipset-all.txt" --hostlist-exclude="%LISTS%list-exclude.txt" --hostlist-exclude="%LISTS%list-exclude-user.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --dpi-desync=fake,split2 --dpi-desync-ttl=autottl --dpi-desync-fooling=badseq --dpi-desync-repeats=6 --dpi-desync-fake-tls="%BIN%tls_clienthello_www_google_com.bin" --dpi-desync-cutoff=n4 --new ^
--filter-tcp=%GameFilterTCP% --ipset="%LISTS%ipset-all.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --dpi-desync=fake,split2 --dpi-desync-ttl=autottl --dpi-desync-fooling=badseq --dpi-desync-repeats=6 --dpi-desync-any-protocol=1 --dpi-desync-cutoff=n4 --dpi-desync-fake-tls="%BIN%tls_clienthello_www_google_com.bin" --new ^
--filter-udp=%GameFilterUDP% --ipset="%LISTS%ipset-all.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --dpi-desync=fake,disorder --dpi-desync-ttl=autottl --dpi-desync-repeats=6 --dpi-desync-any-protocol=1 --dpi-desync-fake-unknown-udp="%BIN%quic_initial_4pda.to.bin" --dpi-desync-cutoff=n2