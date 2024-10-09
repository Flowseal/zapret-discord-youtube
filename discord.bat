@echo off
chcp 65001 >nul
:: 65001 - UTF-8

:: Path check
set scriptPath=%~dp0
set "path_no_spaces=%scriptPath: =%"
if not "%scriptPath%"=="%path_no_spaces%" (
    echo Путь содержит пробелы. 
    echo Пожалуйста, переместите скрипт в директорию без пробелов.
    pause
    exit /b
)

:: Cyrillic check
setlocal enabledelayedexpansion
set "cyrillic_found=0"
for /l %%i in (0,1,127) do (
    set "char=!scriptPath:~%%i,1!"
    for %%c in (А Б В Г Д Е Ё Ж З И Й К Л М Н О П Р С Т У Ф Х Ц Ч Ш Щ Ъ Ы Ь Э Ю Я а б в г д е ё ж з и й к л м н о п р с т у ф х ц ч ш щ ъ ы ь э ю я) do (
        if "!char!"=="%%c" set "cyrillic_found=1"
    )
)
:: This is only way what i found to check if cyrillic character is in string
:: If you know better way, please let me know

if %cyrillic_found% equ 1 (
    echo Путь содержит кириллицу. 
    echo Пожалуйста, переместите скрипт в директорию без кириллических символов.
    echo Кириллица - Русский алфавит.
    pause
    exit /b
)





start "zapret: discord" /min "%~dp0winws.exe" ^
--wf-tcp=443 --wf-udp=443,50000-65535 ^
--filter-udp=443 --hostlist="%~dp0list-discord.txt" --dpi-desync=fake --dpi-desync-udplen-increment=10 --dpi-desync-repeats=6 --dpi-desync-udplen-pattern=0xDEADBEEF --dpi-desync-fake-quic="%~dp0quic_initial_www_google_com.bin" --new ^
--filter-udp=50000-65535 --dpi-desync=fake,tamper --dpi-desync-any-protocol --dpi-desync-fake-quic="%~dp0quic_initial_www_google_com.bin" --new ^
--filter-tcp=443 --hostlist="%~dp0list-discord.txt" --dpi-desync=fake,split2 --dpi-desync-autottl=2 --dpi-desync-fooling=md5sig --dpi-desync-fake-tls="%~dp0tls_clienthello_www_google_com.bin"