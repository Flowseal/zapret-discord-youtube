@echo off
chcp 65001 > nul
:: 65001 - UTF-8
:: NOT RECOMMENDED

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

start "zapret: %~n0" /min "%BIN%winws2.exe" --wf-tcp-out=80,443,2053,2083,2087,2096,8443,%GameFilterTCP% --wf-udp-out=443,19294-19344,50000-50100,%GameFilterUDP% ^
--ipcache-hostname=1 ^
--ipcache-lifetime=86400 ^

--lua-init=@"%LUA%blobs.lua" ^
--lua-init=@"%LUA%zapret-lib.lua" ^
--lua-init=@"%LUA%zapret-antidpi.lua" ^

--template=i ^
--ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" ^
--new ^

--template=h ^
--hostlist-exclude="%LISTS%list-exclude.txt" --hostlist-exclude="%LISTS%list-exclude-user.txt" ^
--import=i ^
--new ^

--name="Domain Quic" ^
--filter-udp=443 ^
--hostlist="%LISTS%list-general.txt"         --hostlist="%LISTS%list-general-user.txt" ^
--import=h ^
--payload=quic_initial ^
--lua-desync=fake:blob=quic_google2:repeats=5 ^
--lua-desync=fake:blob=quic_google3:repeats=1 ^
--lua-desync=udplen:increment=32:min=1200:max=1300 ^
--new ^

--name="Discord Voice" ^
--filter-udp=19294-19344,50000-50100 ^
--filter-l7=discord,stun ^
--payload=discord_ip_discovery,stun ^
--lua-desync=fake:blob=ACTIVE_DISCORD:repeats=6 ^
--lua-desync=fake:blob=quic_google3:repeats=1 ^
--new ^

--name="Domain TLS" ^
--filter-tcp=80,443,2053,2083,2087,2096,8443 ^
--hostlist="%LISTS%list-general.txt" --hostlist="%LISTS%list-general-user.txt" ^
--hostlist="%LISTS%list-google.txt" ^
--import=h --import=i ^
--lua-desync=syndata ^
--payload=tls_client_hello,http_req ^
--lua-desync=fake:blob=tls_google3:tls_mod=rnd,dupsid,sni=www.google.com:tcp_seq=-10000:tcp_ack=-66000:ip_id=zero:repeats=7 ^
--lua-desync=fake:blob=stun2:tcp_seq=-10000:tcp_ack=-66000:ip_id=zero:repeats=3 ^
--lua-desync=multidisorder:pos=1,midsld:ip_id=zero ^
--new ^

--name="GameFilter TCP" ^
--filter-tcp=%GameFilterTCP% ^
--ipset="%LISTS%ipset-all.txt" ^
--import=i ^
--out-range=-n4 ^
--lua-desync=syndata ^
--payload=all ^
--lua-desync=multidisorder:payload=all ^
--new ^

--name="IP Quic" ^
--filter-udp=443 ^
--ipset="%LISTS%ipset-all.txt" ^
--import=h ^
--payload=quic_initial ^
--lua-desync=fake:blob=quic_google:repeats=6 ^
--new ^

--name="GameFilter UDP" ^
--filter-udp=%GameFilterUDP% ^
--ipset="%LISTS%ipset-all.txt" ^
--import=i ^
--out-range=-n3 ^
--payload=all ^
--lua-desync=fake:blob=ACTIVE_GAME:repeats=14:payload=all
