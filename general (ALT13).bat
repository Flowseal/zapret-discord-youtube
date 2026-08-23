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

:: Выносим пути к фейкам в переменные
set "FQUIC_GOOGLE=%BIN%quic_initial_www_google_com.bin"
set "FQUIC_DBANK=%BIN%quic_initial_dbankcloud_ru.bin"
set "FTLS_GOOGLE=%BIN%tls_clienthello_www_google_com.bin"
set "FTLS_4PDA=%BIN%tls_clienthello_4pda_to.bin"

:: Добавляем autottl для улучшения обхода TCP (можно закомментировать)
set "AUTOTTL=--dpi-desync-autottl=3"

:: Формируем списки портов с учётом GameFilter (пустые переменные не добавляем)
set "WF_TCP=80,443,2053,2083,2087,2096,8443"
if not "%GameFilterTCP%"=="" set "WF_TCP=%WF_TCP%,%GameFilterTCP%"

set "WF_UDP=443,19294-19344,50000-50100"
if not "%GameFilterUDP%"=="" set "WF_UDP=%WF_UDP%,%GameFilterUDP%"

cd /d %BIN%

start "zapret: %~n0" /min "%BIN%winws.exe" --wf-tcp=%WF_TCP% --wf-udp=%WF_UDP% ^
--filter-udp=443 --hostlist="%LISTS%list-general.txt" --hostlist="%LISTS%list-general-user.txt" --hostlist-exclude="%LISTS%list-exclude.txt" --hostlist-exclude="%LISTS%list-exclude-user.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --dpi-desync=fake --dpi-desync-repeats=6 --dpi-desync-fake-quic="%FQUIC_GOOGLE%" --new ^
--filter-udp=19294-19344,50000-50100 --filter-l7=discord,stun --dpi-desync=fake --dpi-desync-fake-discord="%FQUIC_DBANK%" --dpi-desync-fake-stun="%FQUIC_DBANK%" --dpi-desync-repeats=6 --new ^
--filter-tcp=2053,2083,2087,2096,8443 --hostlist-domains=discord.media --dpi-desync=fake,multisplit --dpi-desync-fooling=badseq --dpi-desync-repeats=8 --dpi-desync-split-seqovl=681 --dpi-desync-split-pos=1 --dpi-desync-split-seqovl-pattern="%FTLS_GOOGLE%" %AUTOTTL% --new ^
--filter-tcp=443 --hostlist="%LISTS%list-google.txt" --ip-id=zero --dpi-desync=fake,multisplit --dpi-desync-fooling=badseq --dpi-desync-repeats=8 --dpi-desync-split-seqovl=681 --dpi-desync-split-pos=1 --dpi-desync-split-seqovl-pattern="%FTLS_GOOGLE%" %AUTOTTL% --new ^
--filter-tcp=80,443 --hostlist="%LISTS%list-general.txt" --hostlist="%LISTS%list-general-user.txt" --hostlist-exclude="%LISTS%list-exclude.txt" --hostlist-exclude="%LISTS%list-exclude-user.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --dpi-desync=fake,multisplit --dpi-desync-fooling=badseq --dpi-desync-repeats=6 --dpi-desync-split-seqovl=568 --dpi-desync-split-pos=1 --dpi-desync-split-seqovl-pattern="%FTLS_4PDA%" %AUTOTTL% --new ^
--filter-udp=443 --ipset="%LISTS%ipset-all.txt" --hostlist-exclude="%LISTS%list-exclude.txt" --hostlist-exclude="%LISTS%list-exclude-user.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --dpi-desync=fake --dpi-desync-repeats=6 --dpi-desync-fake-quic="%FQUIC_GOOGLE%" --new ^
--filter-tcp=80,443,8443 --ipset="%LISTS%ipset-all.txt" --hostlist-exclude="%LISTS%list-exclude.txt" --hostlist-exclude="%LISTS%list-exclude-user.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --dpi-desync=fake,multisplit --dpi-desync-fooling=badseq --dpi-desync-repeats=6 --dpi-desync-split-seqovl=568 --dpi-desync-split-pos=1 --dpi-desync-split-seqovl-pattern="%FTLS_4PDA%" %AUTOTTL% --new ^
--filter-tcp=%GameFilterTCP% --ipset="%LISTS%ipset-all.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --dpi-desync=multisplit --dpi-desync-any-protocol=1 --dpi-desync-cutoff=n3 --dpi-desync-split-seqovl=568 --dpi-desync-split-pos=1 --dpi-desync-split-seqovl-pattern="%FTLS_4PDA%" %AUTOTTL% --new ^
--filter-udp=%GameFilterUDP% --ipset="%LISTS%ipset-all.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --dpi-desync=fake --dpi-desync-repeats=12 --dpi-desync-any-protocol=1 --dpi-desync-fake-unknown-udp="%FQUIC_DBANK%" --dpi-desync-cutoff=n2
