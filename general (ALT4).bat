@echo off
setlocal EnableDelayedExpansion
chcp 65001 > nul
:: 65001 - UTF-8

call "%~dp0config.bat"

set DISCORD_STRATEGY=--dpi-desync=fake --dpi-desync-repeats=6
set TELEGRAM_VOICECALL_STRATEGY=--dpi-desync=fake --dpi-desync-repeats=6
set TELEGRAM_MEDIA_STRATEGY=--dpi-desync=split2 --dpi-desync-split-seqovl=681 --dpi-desync-split-pos=1,midsld --dpi-desync-split-seqovl-pattern="%FAKE_TLS%" --dpi-desync-any-protocol=1
set WHATSAPP_VOICECALL_STRATEGY=--dpi-desync=fake --dpi-desync-repeats=6
set WHATSAPP_MEDIA_STRATEGY=--dpi-desync=split2 --dpi-desync-split-seqovl=681 --dpi-desync-split-pos=1,midsld --dpi-desync-split-seqovl-pattern="%FAKE_TLS%" --dpi-desync-any-protocol=1
set QUIC_STRATEGY=--dpi-desync=fake --dpi-desync-repeats=6 --dpi-desync-fake-quic="%FAKE_QUIC%"
set UDP_STRATEGY=--dpi-desync=fake --dpi-desync-ttl=6 --dpi-desync-repeats=14 --dpi-desync-any-protocol=1 --dpi-desync-fooling=none --dpi-desync-fake-unknown-udp="%FAKE_UDP%" --dpi-desync-cutoff=n7
set TCP_STRATEGY=--ip-id=zero --dpi-desync=fake,split2 --dpi-desync-repeats=6 --dpi-desync-fooling=md5sig --dpi-desync-fake-tls="%FAKE_TLS%" --dpi-desync-fake-tls-mod=rnd,dupsid,sni=%FAKE_SNI%,padencap

call "%~dp0wrapper.bat" %*