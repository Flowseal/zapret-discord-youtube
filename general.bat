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
cd /d %BIN%

if not exist "%BIN%winws2.exe" (
    echo [ERROR] winws2.exe not found in bin\
    echo Download it from https://github.com/bol-van/zapret2/releases
    echo and put winws2.exe into the bin folder. See README.md
    pause
    exit /b 1
)

start "zapret: %~n0" /min "%BIN%winws2.exe" --wf-tcp-out=80,443,2053,2083,2087,2096,8443,%GameFilterTCP% --wf-udp-out=443,19294-19344,50000-50100,%GameFilterUDP% ^
--lua-init=@"%BIN%lua\zapret-lib.lua" --lua-init=@"%BIN%lua\zapret-antidpi.lua" ^
--blob=quic_initial_www_google_com:@"%BIN%quic_initial_www_google_com.bin" ^
--blob=ACTIVE_DISCORD_UDP:@"%BIN%ACTIVE_DISCORD_UDP.bin" ^
--blob=tls_clienthello_www_google_com:@"%BIN%tls_clienthello_www_google_com.bin" ^
--blob=tls_clienthello_4pda_to:@"%BIN%tls_clienthello_4pda_to.bin" ^
--blob=ACTIVE_GAME_UDP:@"%BIN%ACTIVE_GAME_UDP.bin" ^
--filter-udp=443 ^
--hostlist="%LISTS%list-general.txt" ^
--hostlist="%LISTS%list-general-user.txt" ^
--hostlist-exclude="%LISTS%list-exclude.txt" ^
--hostlist-exclude="%LISTS%list-exclude-user.txt" ^
--ipset-exclude="%LISTS%ipset-exclude.txt" ^
--ipset-exclude="%LISTS%ipset-exclude-user.txt" ^
--payload=quic_initial ^
  --lua-desync=fake:blob=quic_initial_www_google_com:repeats=6 --new ^
--filter-udp=19294-19344,50000-50100 ^
--filter-l7=discord,stun ^
--payload=discord_ip_discovery,stun ^
  --lua-desync=fake:blob=ACTIVE_DISCORD_UDP:repeats=6 --new ^
--filter-tcp=2053,2083,2087,2096,8443 ^
--hostlist-domains=discord.media ^
--out-range=-d10 ^
--payload=tls_client_hello ^
  --lua-desync=multisplit:pos=1:seqovl=681:seqovl_pattern=tls_clienthello_www_google_com ^
--payload=http_req ^
  --lua-desync=multisplit:pos=1:seqovl=681:seqovl_pattern=tls_clienthello_www_google_com --new ^
--filter-tcp=443 ^
--hostlist="%LISTS%list-google.txt" ^
--out-range=-d10 ^
--payload=tls_client_hello ^
  --lua-desync=multisplit:pos=1:seqovl=681:seqovl_pattern=tls_clienthello_www_google_com:ip_id=zero ^
--payload=http_req ^
  --lua-desync=multisplit:pos=1:seqovl=681:seqovl_pattern=tls_clienthello_www_google_com:ip_id=zero --new ^
--filter-tcp=80,443 ^
--hostlist="%LISTS%list-general.txt" ^
--hostlist="%LISTS%list-general-user.txt" ^
--hostlist-exclude="%LISTS%list-exclude.txt" ^
--hostlist-exclude="%LISTS%list-exclude-user.txt" ^
--ipset-exclude="%LISTS%ipset-exclude.txt" ^
--ipset-exclude="%LISTS%ipset-exclude-user.txt" ^
--out-range=-d10 ^
--payload=tls_client_hello ^
  --lua-desync=multisplit:pos=1:seqovl=568:seqovl_pattern=tls_clienthello_4pda_to ^
--payload=http_req ^
  --lua-desync=multisplit:pos=1:seqovl=568:seqovl_pattern=tls_clienthello_4pda_to --new ^
--filter-udp=443 ^
--ipset="%LISTS%ipset-all.txt" ^
--hostlist-exclude="%LISTS%list-exclude.txt" ^
--hostlist-exclude="%LISTS%list-exclude-user.txt" ^
--ipset-exclude="%LISTS%ipset-exclude.txt" ^
--ipset-exclude="%LISTS%ipset-exclude-user.txt" ^
--payload=quic_initial ^
  --lua-desync=fake:blob=quic_initial_www_google_com:repeats=6 --new ^
--filter-tcp=80,443,8443 ^
--ipset="%LISTS%ipset-all.txt" ^
--hostlist-exclude="%LISTS%list-exclude.txt" ^
--hostlist-exclude="%LISTS%list-exclude-user.txt" ^
--ipset-exclude="%LISTS%ipset-exclude.txt" ^
--ipset-exclude="%LISTS%ipset-exclude-user.txt" ^
--out-range=-d10 ^
--payload=tls_client_hello ^
  --lua-desync=multisplit:pos=1:seqovl=568:seqovl_pattern=tls_clienthello_4pda_to ^
--payload=http_req ^
  --lua-desync=multisplit:pos=1:seqovl=568:seqovl_pattern=tls_clienthello_4pda_to --new ^
--filter-tcp=%GameFilterTCP% ^
--ipset="%LISTS%ipset-all.txt" ^
--ipset-exclude="%LISTS%ipset-exclude.txt" ^
--ipset-exclude="%LISTS%ipset-exclude-user.txt" ^
--out-range=-d3 ^
--payload=tls_client_hello ^
  --lua-desync=multisplit:pos=1:seqovl=568:seqovl_pattern=tls_clienthello_4pda_to:payload=all ^
--payload=http_req ^
  --lua-desync=multisplit:pos=1:seqovl=568:seqovl_pattern=tls_clienthello_4pda_to:payload=all ^
--payload=unknown ^
  --lua-desync=multisplit:pos=1:seqovl=568:seqovl_pattern=tls_clienthello_4pda_to:payload=all --new ^
--filter-udp=%GameFilterUDP% ^
--ipset="%LISTS%ipset-all.txt" ^
--ipset-exclude="%LISTS%ipset-exclude.txt" ^
--ipset-exclude="%LISTS%ipset-exclude-user.txt" ^
--payload=all ^
  --lua-desync=fake:blob=ACTIVE_GAME_UDP:repeats=12:payload=all
