@echo off
chcp 65001 > nul
:: 65001 - UTF-8

cd /d "%~dp0"
call service.bat status_zapret
call service.bat check_updates
call service.bat load_game_filter
call service.bat load_user_lists
echo:

set "BIN=%~dp0bin\"
set "LISTS=%~dp0lists\"
set "LUA=%~dp0lua\"
cd /d %BIN%

start "zapret: %~n0" /min "%BIN%winws2.exe" --debug=0 --wf-tcp-out=80,443,2053,2083,2087,2096,8443,%GameFilterTCP% --wf-udp-out=443,19294-19344,50000-50100,%GameFilterUDP% ^

--lua-init=@"%LUA%blobs.lua" ^
--lua-init=@"%LUA%zapret-lib.lua" ^
--lua-init=@"%LUA%zapret-antidpi.lua" ^

--name="Domain Bypass Quic" ^
--filter-udp=443 ^
--hostlist="%LISTS%list-general.txt"         --hostlist="%LISTS%list-general-user.txt" ^
--hostlist-exclude="%LISTS%list-exclude.txt" --hostlist-exclude="%LISTS%list-exclude-user.txt" ^
--ipset-exclude="%LISTS%ipset-exclude.txt"   --ipset-exclude="%LISTS%ipset-exclude-user.txt" ^
--payload=quic_initial ^
--lua-desync=fake:blob=quic_google:repeats=6 ^
--new ^

--name="Discord Voice" ^
--filter-udp=19294-19344,50000-50100 ^
--filter-l7=discord,stun ^
--payload=discord_ip_discovery,stun ^
--lua-desync=fake:blob=ACTIVE_DISCORD:repeats=6 ^
--new ^

--name="Discord Media" ^
--filter-tcp=2053,2083,2087,2096,8443 ^
--hostlist-domains=discord.media ^
--payload=tls_client_hello ^
--lua-desync=fake:blob=tls_google:tcp_ts=-600000:repeats=6 ^
--new ^

--name="Youtube" ^
--filter-tcp=443 ^
--hostlist="%LISTS%list-google.txt" ^
--payload=tls_client_hello ^
--lua-desync=fake:blob=tls_google:tcp_ts=-600000:ip_id=zero:repeats=6 ^
--new ^

--name="Domain Bypass TLS" ^
--filter-tcp=80,443 ^
--hostlist="%LISTS%list-general.txt"         --hostlist="%LISTS%list-general-user.txt" ^
--hostlist-exclude="%LISTS%list-exclude.txt" --hostlist-exclude="%LISTS%list-exclude-user.txt" ^
--ipset-exclude="%LISTS%ipset-exclude.txt"   --ipset-exclude="%LISTS%ipset-exclude-user.txt" ^
--payload=tls_client_hello ^
--lua-desync=fake:blob=stun2:tcp_ts=-600000:repeats=6 ^
--lua-desync=fake:blob=tls_sferum:tcp_ts=-600000:repeats=6 ^
--payload=http_req ^
--lua-desync=fake:blob=tls_sferum:tcp_ts=-600000:repeats=6 ^
--new ^

--name="IP Bypass Quic" ^
--filter-udp=443 ^
--ipset="%LISTS%ipset-all.txt" ^
--hostlist-exclude="%LISTS%list-exclude.txt" --hostlist-exclude="%LISTS%list-exclude-user.txt" ^
--ipset-exclude="%LISTS%ipset-exclude.txt"   --ipset-exclude="%LISTS%ipset-exclude-user.txt" ^
--payload=quic_initial ^
--lua-desync=fake:blob=quic_google:repeats=6 ^
--new ^

--name="IP Bypass TLS" ^
--filter-tcp=80,443,8443 ^
--ipset="%LISTS%ipset-all.txt" ^
--hostlist-exclude="%LISTS%list-exclude.txt" --hostlist-exclude="%LISTS%list-exclude-user.txt" ^
--ipset-exclude="%LISTS%ipset-exclude.txt"   --ipset-exclude="%LISTS%ipset-exclude-user.txt" ^
--payload=tls_client_hello ^
--lua-desync=fake:blob=stun2:tcp_ts=-600000:repeats=6 ^
--lua-desync=fake:blob=tls_sferum:tcp_ts=-600000:repeats=6 ^
--payload=http_req ^
--lua-desync=fake:blob=tls_sferum:tcp_ts=-600000:repeats=6 ^
--new ^

--name="GameFilter Bypass TCP" ^
--filter-tcp=%GameFilterTCP% ^
--ipset="%LISTS%ipset-all.txt" ^
--ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" ^
--out-range=-n5 ^
--payload=tls_client_hello ^
--lua-desync=fake:blob=stun2:tcp_ts=-600000:repeats=6 ^
--lua-desync=fake:blob=tls_sferum:tcp_ts=-600000:repeats=6 ^
--payload=http_req ^
--lua-desync=fake:blob=tls_sferum:tcp_ts=-600000:repeats=6 ^
--payload=unknown ^
--lua-desync=fake:blob=stun2:tcp_ts=-600000:repeats=6:payload=all ^
--lua-desync=fake:blob=tls_sferum:tcp_ts=-600000:repeats=6:payload=all ^
--new ^

--name="GameFilter Bypass UDP" ^
--filter-udp=%GameFilterUDP% ^
--ipset="%LISTS%ipset-all.txt" ^
--ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" ^
--out-range=-n3 ^
--payload=all ^
--lua-desync=fake:blob=ACTIVE_GAME:repeats=12:payload=all
