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
set QUIC_STRATEGY=--dpi-desync=fake --dpi-desync-repeats=8 --dpi-desync-fake-quic="%FAKE_QUIC%" --dpi-desync-udplen-increment=6 --dpi-desync-udplen-pattern=0xDEADBEEF
set UDP_STRATEGY=--dpi-desync=fake --dpi-desync-repeats=12 --dpi-desync-autottl=2 --dpi-desync-any-protocol=1 --dpi-desync-cutoff=n2 --dpi-desync-fake-unknown-udp="%FAKE_UDP%"
set TCP_STRATEGY=--ip-id=zero --dpi-desync=fake --dpi-desync-repeats=6 --dpi-desync-fooling=ts --dpi-desync-fake-tls="%FAKE_TLS%"

call "%~dp0wrapper.bat" %*