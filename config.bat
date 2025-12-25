@echo off

set "MARKER=%~n0"

set "SCRIPTS_DIR=%~dp0"
set "FUNCTIONS_SCRIPT=%SCRIPTS_DIR%functions.bat"

@REM if "%1"=="" (
@REM 	set ZAPRET_BASE="%~dp0"
@REM ) else (
@REM 	set ZAPRET_BASE="%1"
@REM )
set "ZAPRET_BASE=%~dp0"
set "ZAPRET_BIN=%ZAPRET_BASE%bin\"
set "ZAPRET_LISTS=%ZAPRET_BASE%lists\"
set "ZAPRET_CUSTOM=%ZAPRET_LISTS%custom\"

@REM WINWS CONFIGURATION begin
set "DRIVER_NAME=Monkey"
set "IMAGE_NAME=winws.exe"
set "CONFICTING_SERVICES=discordfix_zapret winws1 winws2"
@REM end

@REM SERVICE configuration begin
set "SERVICE_NAME=zapret"
set "SERVICE_DESCRIPTION=Zapret DPI bypass software"
set "SERVICE_DISPLAY_NAME=AntiZapret"
set "SERVICE_BOOT_FLAG=auto"
@REM end

@REM UPDATE configuration begin
@REM Set current version and URLs
set "GITHUB_VERSION_URL=https://raw.githubusercontent.com/fluffydaddy/zapret-discord-youtube/main/.service/version.txt"
set "GITHUB_RELEASE_URL=https://github.com/fluffydaddy/zapret-discord-youtube/releases/tag/"
set "GITHUB_DOWNLOAD_URL=https://github.com/fluffydaddy/zapret-discord-youtube/releases/latest/download/zapret-discord-youtube-"
@REM end

@REM Base lists begin
@REM set "IPSET_CLOUDFLARE_FILE=%ZAPRET_CUSTOM%ipset-cloudflare.txt"
@REM set "IPSET_CLOUDFLARE_URL=https://raw.githubusercontent.com/V3nilla/IPSets-For-Bypass-in-Russia/refs/heads/main/ipset-cloudflare.txt"

@REM set "IPSET_AMAZON_FILE=%ZAPRET_CUSTOM%ipset-amazon.txt"
@REM set "IPSET_AMAZON_URL=https://raw.githubusercontent.com/V3nilla/IPSets-For-Bypass-in-Russia/refs/heads/main/ipset-amazon.txt"
set "LIST_GENERAL_FILE=%ZAPRET_CUSTOM%list-general.txt"
set "LIST_GENERAL_URL=https://p.thenewone.lol/domains-export.txt"

set "IPSET_ALL_FILE=%ZAPRET_CUSTOM%ipset-all.txt"
set "IPSET_ALL_URL=https://raw.githubusercontent.com/V3nilla/IPSets-For-Bypass-in-Russia/refs/heads/main/ipset-all.txt"
@REM end

@REM HOST/IPSET files begin
set "ZAPRET_IPSET=%ZAPRET_LISTS%zapret-ipset.txt"
set "ZAPRET_HOSTS=%ZAPRET_LISTS%zapret-hosts.txt"
set "ZAPRET_HOSTS_AUTO=%ZAPRET_LISTS%zapret-hosts-auto.txt"

set "ZAPRET_IPSET_USER=%ZAPRET_LISTS%zapret-ipset-user.txt"
set "ZAPRET_IPSET_EXCLUDE=%ZAPRET_LISTS%zapret-ipset-exclude.txt"

set "ZAPRET_HOSTS_USER=%ZAPRET_LISTS%zapret-hosts-user.txt"
set "ZAPRET_HOSTS_EXCLUDE=%ZAPRET_LISTS%zapret-hosts-exclude.txt"

@REM 91.108.56.0/22,91.108.4.0/22,91.108.8.0/22,91.108.16.0/22,91.108.12.0/22,149.154.160.0/20,91.105.192.0/23,91.108.20.0/22,185.76.151.0/24,2001:b28:f23d::/48,2001:b28:f23f::/48,2001:67c:4e8::/48,2001:b28:f23c::/48,2a0a:f280::/32
set "ZAPRET_IPSET_TELEGRAM=%ZAPRET_LISTS%zapret-ipset-telegram.txt"
@REM 31.13.24.0/17,45.64.40.0/22,57.141.0.0/20,57.144.0.0/14,66.220.144.0/20,69.63.176.0/20,69.171.224.0/19,74.119.76.0/22,102.132.96.0/20,103.4.96.0/22,129.134.0.0/17,157.240.0.0/17,157.240.192.0/18,163.70.128.0/17,173.252.64.0/19,173.252.96.0/19,179.60.192.0/22,185.60.216.0/22,204.15.20.0/22
set "ZAPRET_IPSET_WHATSAPP=%ZAPRET_LISTS%zapret-ipset-whatsapp.txt"
@REM end

@REM FAKES begin
set "FAKE_QUIC=%ZAPRET_BIN%quic_initial_www_google_com.bin"
set "FAKE_UDP=%ZAPRET_BIN%quic_short_header.bin"
set "FAKE_TLS=%ZAPRET_BIN%tls_clienthello_max_ru.bin"
set "FAKE_SNI=max.ru"
@REM end
