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

:: Пути к фейковым файлам (для удобства)
set "FQUIC=%BIN%quic_initial_www_google_com.bin"
set "FTLS=%BIN%tls_clienthello_www_google_com.bin"
set "FMAX=%BIN%tls_clienthello_max_ru.bin"
set "FSTUN=%BIN%stun.bin"
set "FDISCORD=%BIN%ACTIVE_DISCORD_UDP.bin"
set "FGAME=%BIN%ACTIVE_GAME_UDP.bin"

:: Новые параметры (можно менять или закомментировать)
set "AUTOTTL=--dpi-desync-autottl=3"
set "FAKEDSPLIT_MOD=--dpi-desync-fakedsplit-mod=altorder=2"

:: Формируем списки портов для --wf-tcp и --wf-udp с учётом GameFilter
set "WF_TCP=80,443,2053,2083,2087,2096,8443"
if not "%GameFilterTCP%"=="" set "WF_TCP=%WF_TCP%,%GameFilterTCP%"
set "WF_UDP=443,19294-19344,50000-50100"
if not "%GameFilterUDP%"=="" set "WF_UDP=%WF_UDP%,%GameFilterUDP%"

cd /d %BIN%

start "zapret: %~n0" /min "%BIN%winws.exe" --wf-tcp=%WF_TCP% --wf-udp=%WF_UDP% ^
--filter-udp=443 --hostlist="%LISTS%list-general.txt" --hostlist="%LISTS%list-general-user.txt" --hostlist-exclude="%LISTS%list-exclude.txt" --hostlist-exclude="%LISTS%list-exclude-user.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --dpi-desync=fake --dpi-desync-repeats=6 --dpi-desync-fake-quic="%FQUIC%" --new ^
--filter-udp=19294-19344,50000-50100 --filter-l7=discord,stun --dpi-desync=fake --dpi-desync-fake-discord="%FDISCORD%" --dpi-desync-fake-stun="%FDISCORD%" --dpi-desync-repeats=6 --new ^
--filter-tcp=2053,2083,2087,2096,8443 --hostlist-domains=discord.media --dpi-desync=fake,fakedsplit --dpi-desync-repeats=6 --dpi-desync-fooling=ts --dpi-desync-fakedsplit-pattern=0x00 --dpi-desync-fake-tls="%FTLS%" --new ^
--filter-tcp=443 --hostlist="%LISTS%list-google.txt" --ip-id=zero --dpi-desync=fake,fakedsplit --dpi-desync-repeats=6 --dpi-desync-fooling=ts --dpi-desync-fakedsplit-pattern=0x00 --dpi-desync-fake-tls="%FTLS%" --new ^
--filter-tcp=80,443 --hostlist="%LISTS%list-general.txt" --hostlist="%LISTS%list-general-user.txt" --hostlist-exclude="%LISTS%list-exclude.txt" --hostlist-exclude="%LISTS%list-exclude-user.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --dpi-desync=fake,fakedsplit --dpi-desync-repeats=6 --dpi-desync-fooling=ts --dpi-desync-fakedsplit-pattern=0x00 %AUTOTTL% %FAKEDSPLIT_MOD% --dpi-desync-fake-tls="%FSTUN%" --dpi-desync-fake-tls="%FTLS%" --dpi-desync-fake-http="%FMAX%" --new ^
--filter-udp=443 --ipset="%LISTS%ipset-all.txt" --hostlist-exclude="%LISTS%list-exclude.txt" --hostlist-exclude="%LISTS%list-exclude-user.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --dpi-desync=fake --dpi-desync-repeats=6 --dpi-desync-fake-quic="%FQUIC%" --new ^
--filter-tcp=80,443,8443 --ipset="%LISTS%ipset-all.txt" --hostlist-exclude="%LISTS%list-exclude.txt" --hostlist-exclude="%LISTS%list-exclude-user.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --dpi-desync=fake,fakedsplit --dpi-desync-repeats=6 --dpi-desync-fooling=ts --dpi-desync-fakedsplit-pattern=0x00 %AUTOTTL% %FAKEDSPLIT_MOD% --dpi-desync-fake-tls="%FSTUN%" --dpi-desync-fake-tls="%FTLS%" --dpi-desync-fake-http="%FMAX%" --new ^
--filter-tcp=%GameFilterTCP% --ipset="%LISTS%ipset-all.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --dpi-desync=fake,fakedsplit --dpi-desync-repeats=6 --dpi-desync-any-protocol=1 --dpi-desync-cutoff=n4 --dpi-desync-fooling=ts --dpi-desync-fakedsplit-pattern=0x00 --dpi-desync-fake-tls="%FSTUN%" --dpi-desync-fake-tls="%FTLS%" --dpi-desync-fake-http="%FMAX%" --dpi-desync-fake-unknown="%FSTUN%" --dpi-desync-fake-unknown="%FTLS%" --new ^
--filter-udp=%GameFilterUDP% --ipset="%LISTS%ipset-all.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --dpi-desync=fake --dpi-desync-repeats=12 --dpi-desync-any-protocol=1 --dpi-desync-fake-unknown-udp="%FGAME%" --dpi-desync-cutoff=n3
