@echo off

if not defined MARKER (
	echo This is a wrapper, not a program for end use!
	pause
	exit 1
)

setlocal EnableDelayedExpansion
set ARGUMENTS=--wf-tcp=80,443,2053,2083,2087,2096,5222,8443,1024-65535 --wf-udp=443,1400,590-1400,3478,3482,19294-19344,50000-50100,1024-65535

set ARGUMENTS=!ARGUMENTS! --filter-udp=19294-19344,50000-50100 --filter-l7=discord,stun %DISCORD_STRATEGY% --new
set ARGUMENTS=!ARGUMENTS! --filter-tcp=2053,2083,2087,2096,8443 --hostlist-domains=discord.media %TCP_STRATEGY% --new
set ARGUMENTS=!ARGUMENTS! --filter-tcp=443 --filter-l7=tls --ipset-ip=162.159.36.1,162.159.46.1,2606:4700:4700::1111,2606:4700:4700::1001 %TCP_STRATEGY% --new

set ARGUMENTS=!ARGUMENTS! --filter-udp=443 --hostlist-exclude="%ZAPRET_HOSTS_EXCLUDE%" --ipset-exclude="%ZAPRET_IPSET_EXCLUDE%" --hostlist="%ZAPRET_HOSTS_USER%" --hostlist="%ZAPRET_HOSTS%" --hostlist="%ZAPRET_HOSTS_AUTO%" %QUIC_STRATEGY% --new
set ARGUMENTS=!ARGUMENTS! --filter-tcp=80,443,1024-65535 --ipset="%ZAPRET_IPSET_USER%" --ipset="%ZAPRET_IPSET%" --hostlist-exclude="%ZAPRET_HOSTS_EXCLUDE%" --ipset-exclude="%ZAPRET_IPSET_EXCLUDE%" --hostlist-auto="%ZAPRET_HOSTS_AUTO%" %TCP_STRATEGY% --new
set ARGUMENTS=!ARGUMENTS! --filter-udp=1400 --filter-l7=stun --ipset="%ZAPRET_IPSET_TELEGRAM%" %TELEGRAM_VOICECALL_STRATEGY% --new
set ARGUMENTS=!ARGUMENTS! --filter-tcp=443,5222 --ipset="%ZAPRET_IPSET_TELEGRAM%" %TELEGRAM_MEDIA_STRATEGY% --new
set ARGUMENTS=!ARGUMENTS! --filter-udp=590-1400,3478,3482 --filter-l7=stun --ipset="%ZAPRET_IPSET_WHATSAPP%" %WHATSAPP_VOICECALL_STRATEGY% --new
set ARGUMENTS=!ARGUMENTS! --filter-tcp=443,5222 --ipset="%ZAPRET_IPSET_WHATSAPP%" %WHATSAPP_MEDIA_STRATEGY% --new
set ARGUMENTS=!ARGUMENTS! --filter-udp=443,1024-65535 --ipset="%ZAPRET_IPSET_USER%" --ipset="%ZAPRET_IPSET%" --hostlist-exclude="%ZAPRET_HOSTS_EXCLUDE%" --ipset-exclude="%ZAPRET_IPSET_EXCLUDE%" %UDP_STRATEGY%

if not exist "%ZAPRET_IPSET_USER%" (
	type NUL >"%ZAPRET_IPSET_USER%"
)
if not exist "%ZAPRET_HOSTS_USER%" (
	type NUL >"%ZAPRET_HOSTS_USER%"
)
if not exist "%ZAPRET_HOSTS_AUTO%" (
	type NUL >"%ZAPRET_HOSTS_AUTO%"
)
if not exist "%ZAPRET_HOSTS_EXCLUDE%" (
	type NUL >"%ZAPRET_HOSTS_EXCLUDE%"
)
if not exist "%ZAPRET_IPSET_EXCLUDE%" (
	type NUL >"%ZAPRET_IPSET_EXCLUDE%"
)

call "%FUNCTIONS_SCRIPT%" combine

:: External commands
set "WHAT=%~1"
shift

if "%WHAT%"=="install" (
	goto :install
) else (
	goto :main
)

goto :eof


:main

cd /d "%ZAPRET_BASE%"
call service.bat status_zapret
call service.bat check_updates
echo:

start "zapret: %~n0" /min "%ZAPRET_BIN%%IMAGE_NAME%" %ARGUMENTS%

goto :eof


:install
rem The arguments passed to the program calling this instance.

call "%FUNCTIONS_SCRIPT%" escape "!ARGUMENTS!" ARG_ESCAPED

sc create "%SERVICE_NAME%" binPath= "\"%ZAPRET_BIN%%IMAGE_NAME%\" !ARG_ESCAPED!" start= "%SERVICE_BOOT_FLAG%"

goto :eof

