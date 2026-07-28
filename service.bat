@echo off
set "LOCAL_VERSION=1.10.0"

:: External commands
if "%~1"=="status_zapret" (
    call :test_service zapret soft
    call :tcp_enable
    exit /b
)

if "%~1"=="check_updates" (
    if defined NO_UPDATE_CHECK exit /b

    if exist "%~dp0utils\check_updates.enabled" (
        if not "%~2"=="soft" (
            start /b service check_updates soft
        ) else (
            call :service_check_updates soft
        )
    )

    exit /b
)

if "%~1"=="load_game_filter" (
    call :game_switch_status
    exit /b
)

if "%~1"=="load_user_lists" (
    call :load_user_lists
    exit /b
)

if "%1"=="admin" (
    call :check_command chcp
    call :check_command find
    call :check_command findstr
    call :check_command netsh
    
    call :load_user_lists

    echo Started with admin rights
) else (
    call :check_extracted
    call :check_command powershell

    echo Requesting admin rights...
    powershell -NoProfile -Command "Start-Process 'cmd.exe' -ArgumentList '/c \"\"%~f0\" admin\"' -Verb RunAs"
    exit
)


:: MENU ================================
title ZAPRET SERVICE MANAGER v%LOCAL_VERSION%
:menu

cls

call :ipset_switch_status
call :game_switch_status
call :check_updates_switch_status
call :get_strategy_name

set "menu_choice=null"

echo.
echo   ZAPRET SERVICE MANAGER v%LOCAL_VERSION%
echo.  %CurrentStrategy%
echo   ----------------------------------------
echo.
echo   :: SERVICE
echo      1. Install Service
echo      2. Remove Services
echo      3. Check Status
echo.
echo   :: SETTINGS
echo      4. Game Filter         [%GameFilterStatus%]
echo      5. IPSet Filter        [%IPsetStatus%]
echo      6. Auto-Update Check   [%CheckUpdatesStatus%]
echo      7. Replace active fakes
echo.
echo   :: UPDATES
echo      8. Update IPSet List
echo      9. Update Hosts File
echo      10. Check for Updates
echo.
echo   :: TOOLS
echo      11. Run Diagnostics
echo      12. Run Tests
echo.
echo   ----------------------------------------
echo      0. Exit
echo.

set /p menu_choice=   Select option (0-12): 

if "%menu_choice%"=="1" goto service_install
if "%menu_choice%"=="2" goto service_remove
if "%menu_choice%"=="3" goto service_status
if "%menu_choice%"=="4" goto game_switch
if "%menu_choice%"=="5" goto ipset_switch
if "%menu_choice%"=="6" goto check_updates_switch
if "%menu_choice%"=="7" goto replace_active_fakes
if "%menu_choice%"=="8" goto ipset_update
if "%menu_choice%"=="9" goto hosts_update
if "%menu_choice%"=="10" goto service_check_updates
if "%menu_choice%"=="11" goto service_diagnostics
if "%menu_choice%"=="12" goto run_tests
if "%menu_choice%"=="0" exit /b
goto menu


:: LOAD USER LISTS =====================
:load_user_lists
set "LISTS_PATH=%~dp0lists\"

if not exist "%LISTS_PATH%ipset-exclude-user.txt" (
    echo 203.0.113.113/32>"%LISTS_PATH%ipset-exclude-user.txt"
)
if not exist "%LISTS_PATH%list-general-user.txt" (
    echo # Never leave this file empty>"%LISTS_PATH%list-general-user.txt"
    echo domain.example.abc>>"%LISTS_PATH%list-general-user.txt"
)
if not exist "%LISTS_PATH%list-exclude-user.txt" (
    echo domain.example.abc>"%LISTS_PATH%list-exclude-user.txt"
)

exit /b


:: TCP ENABLE ==========================
:tcp_enable
chcp 437 > nul
netsh interface tcp show global | findstr /i "timestamps" | findstr /i "enabled" > nul || netsh interface tcp set global timestamps=enabled > nul 2>&1
exit /b


:: STATUS ==============================
:service_status
cls
chcp 437 > nul

sc query "zapret" >nul 2>&1
if %errorlevel%==0 (
    for /f "tokens=2*" %%A in ('reg query "HKLM\System\CurrentControlSet\Services\zapret" /v zapret-discord-youtube 2^>nul') do echo Service strategy installed from "%%B"
)

call :test_service zapret
call :test_service WinDivert

set "BIN_PATH=%~dp0bin\"
if not exist "%BIN_PATH%\*.sys" (
    call :PrintRed "WinDivert64.sys file NOT found."
)
echo:

tasklist /FI "IMAGENAME eq winws.exe" | find /I "winws.exe" > nul
if %errorlevel%==0 (
    call :PrintGreen "Bypass (winws.exe) is RUNNING."
) else (
    call :PrintRed "Bypass (winws.exe) is NOT running."
)

pause
goto menu

:test_service
set "ServiceName=%~1"
set "ServiceStatus="

for /f "tokens=3 delims=: " %%A in ('sc query "%ServiceName%" ^| findstr /i "STATE"') do set "ServiceStatus=%%A"
set "ServiceStatus=%ServiceStatus: =%"

if "%ServiceStatus%"=="RUNNING" (
    if "%~2"=="soft" (
        echo "%ServiceName%" is ALREADY RUNNING as service, use "service.bat" and choose "Remove Services" first if you want to run standalone bat.
        pause
        exit /b
    ) else (
        echo "%ServiceName%" service is RUNNING.
    )
) else if "%ServiceStatus%"=="STOP_PENDING" (
    call :PrintYellow "%ServiceName% is STOP_PENDING, that may be caused by a conflict with another bypass. Run Diagnostics to try to fix conflicts"
) else if not "%~2"=="soft" (
    echo "%ServiceName%" service is NOT running.
)

exit /b


:: REMOVE ==============================
:service_remove
cls
chcp 65001 > nul

set SRVCNAME=zapret
sc query "%SRVCNAME%" >nul 2>&1
if %errorlevel%==0 (
    net stop %SRVCNAME%
    sc delete %SRVCNAME%
) else (
    echo Service "%SRVCNAME%" is not installed.
)

tasklist /FI "IMAGENAME eq winws.exe" | find /I "winws.exe" > nul
if %errorlevel%==0 (
    taskkill /IM winws.exe /F > nul
)

sc query "WinDivert" >nul 2>&1
if %errorlevel%==0 (
    net stop "WinDivert"
)
sc query "WinDivert" >nul 2>&1
if %errorlevel%==0 (
	sc delete "WinDivert"
)
net stop "WinDivert14" >nul 2>&1
sc delete "WinDivert14" >nul 2>&1

pause
goto menu


:: INSTALL =============================
:service_install
cls
chcp 437 > nul

:: Main
cd /d "%~dp0"
set "BIN_PATH=%~dp0bin\"
set "LISTS_PATH=%~dp0lists\"

:: Searching for .bat files in current folder, except files that start with "service"
echo Pick one of the options:
set "count=0"
for /f "delims=" %%F in ('powershell -NoProfile -Command "Get-ChildItem -LiteralPath '.' -Filter '*.bat' | Where-Object { $_.Name -notlike 'service*' } | Sort-Object { [Regex]::Replace($_.Name, '(\d+)', { $args[0].Value.PadLeft(8, '0') }) } | ForEach-Object { $_.Name }"') do (
    call :service_install_add_file_to_list "%%F"
)
goto :service_install_add_file_to_list_finished

:service_install_add_file_to_list
set /a count+=1
echo   %count%. %~1
set "file%count%=%~1"
exit /b 0
:service_install_add_file_to_list_finished

echo   0. Exit

echo.

:: Choosing file
set "choice="
set /p "choice=Input option (0-%count%, default: 0): "
if "%choice%"=="" (
    set "choice=0"
)

if "%choice%"=="0" (
    goto menu
)

call set "selectedFile=%%file%choice%%%"
if not defined selectedFile (
    echo Invalid choice, exiting...
    pause
    goto menu
)

set "capture=0"

set "BIN=%BIN_PATH%"
set "LISTS=%LISTS_PATH%"
for /f "tokens=*" %%a in ('type "%selectedFile%"') do (
    call :service_install_parse_line %%a
)
goto :service_install_parse_line_finished

:service_install_parse_line
	(set "line=%*") 1>nul 2>nul
	(set "line=%line:^=%") 1>nul 2>nul

	if %capture% == 1 (
		set "ARGS=%ARGS% %line%"
		exit /b 0
	)

	echo %line% | findstr /i "winws.exe" 1>nul 2>nul
	if not errorlevel 1 (
		set "ARGS=%line:*--wf=--wf%"
		set "capture=1"
	)
	exit /b 0
:service_install_parse_line_finished

:: Creating service with parsed args
call :tcp_enable

set "BIN="
set "LISTS="
set "ARGS=%ARGS:"=\"%"
set "ARGS=%ARGS:  = %"
echo Final args: %ARGS%
set SRVCNAME=zapret

net stop %SRVCNAME% >nul 2>&1
sc delete %SRVCNAME% >nul 2>&1
sc create %SRVCNAME% binPath= "\"%BIN_PATH%winws.exe\" %ARGS%" DisplayName= "zapret" start= auto
sc description %SRVCNAME% "Zapret DPI bypass software"
sc start %SRVCNAME%
call set "current_choice_file=%%file%choice%%%"
for %%F in ("%current_choice_file%") do (
    set "filename=%%~nF"
)
reg add "HKLM\System\CurrentControlSet\Services\zapret" /v zapret-discord-youtube /t REG_SZ /d "%filename%" /f

pause
goto menu


:: CHECK UPDATES =======================
:service_check_updates
chcp 437 > nul
cls

:: Set current version and URLs
set "GITHUB_VERSION_URL=https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/main/.service/version.txt"
set "GITHUB_RELEASE_URL=https://github.com/Flowseal/zapret-discord-youtube/releases/tag/"
set "GITHUB_DOWNLOAD_URL=https://github.com/Flowseal/zapret-discord-youtube/releases/latest"

:: Get the latest version from GitHub
for /f "delims=" %%A in ('powershell -NoProfile -Command "(Invoke-WebRequest -Uri \"%GITHUB_VERSION_URL%\" -Headers @{\"Cache-Control\"=\"no-cache\"} -UseBasicParsing -TimeoutSec 5).Content.Trim()" 2^>nul') do set "GITHUB_VERSION=%%A"

:: Error handling
if not defined GITHUB_VERSION (
    echo Warning: failed to fetch the latest version. This warning does not affect the operation of zapret
    timeout /T 9
    if "%1"=="soft" exit 
    goto menu
)

:: Version comparison
if "%LOCAL_VERSION%"=="%GITHUB_VERSION%" (
    echo Latest version installed: %LOCAL_VERSION%
    
    if "%1"=="soft" exit 
    pause
    goto menu
) 

echo New version available: %GITHUB_VERSION%
echo Release page: %GITHUB_RELEASE_URL%%GITHUB_VERSION%

echo Opening the download page...
start "" "%GITHUB_DOWNLOAD_URL%"


if "%1"=="soft" exit 
pause
goto menu



:: DIAGNOSTICS =========================
:service_diagnostics
chcp 437 > nul
cls

:: Base Filtering Engine
sc query BFE | findstr /I "RUNNING" > nul
if %errorlevel%==0 (
    call :PrintGreen "Base Filtering Engine check passed"
) else (
    call :PrintRed "[X] Base Filtering Engine is not running. This service is required for zapret to work"
)
echo:

:: Proxy check
set "proxyEnabled=0"
set "proxyServer="

for /f "tokens=2*" %%A in ('reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyEnable 2^>nul ^| findstr /i "ProxyEnable"') do (
    if "%%B"=="0x1" set "proxyEnabled=1"
)

if %proxyEnabled%==0 (
    call :PrintGreen "Proxy check passed"
	goto :service_diagnostics_proxy_check_finished
)
for /f "tokens=2*" %%A in ('reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyServer 2^>nul ^| findstr /i "ProxyServer"') do (
	set "proxyServer=%%B"
)
call :PrintYellow "[?] System proxy is enabled: %proxyServer%"
call :PrintYellow "Make sure it's valid or disable it if you don't use a proxy"
:service_diagnostics_proxy_check_finished
echo:

:: TCP timestamps check
netsh interface tcp show global | findstr /i "timestamps" | findstr /i "enabled" > nul
if %errorlevel%==0 (
    call :PrintGreen "TCP timestamps check passed"
	goto :service_diagnostics_skip_tcp_timestamps
)
call :PrintYellow "[?] TCP timestamps are disabled. Enabling timestamps..."
netsh interface tcp set global timestamps=enabled > nul 2>&1
if %errorlevel%==0 (
	call :PrintGreen "TCP timestamps successfully enabled"
) else (
	call :PrintRed "[X] Failed to enable TCP timestamps"
)
:service_diagnostics_skip_tcp_timestamps
echo:

:: AdguardSvc.exe
tasklist /FI "IMAGENAME eq AdguardSvc.exe" | find /I "AdguardSvc.exe" > nul
if %errorlevel%==0 (
    call :PrintRed "[X] Adguard process found. Adguard may cause problems with Discord"
    call :PrintRed "https://github.com/Flowseal/zapret-discord-youtube/issues/417"
) else (
    call :PrintGreen "Adguard check passed"
)
echo:

:: Killer
sc query | findstr /I "Killer" > nul
if %errorlevel%==0 (
    call :PrintRed "[X] Killer services found. Killer conflicts with zapret"
    call :PrintRed "https://github.com/Flowseal/zapret-discord-youtube/issues/2512#issuecomment-2821119513"
) else (
    call :PrintGreen "Killer check passed"
)
echo:

:: Intel Connectivity Network Service
sc query | findstr /I "Intel" | findstr /I "Connectivity" | findstr /I "Network" > nul
if %errorlevel%==0 (
    call :PrintRed "[X] Intel Connectivity Network Service found. It conflicts with zapret"
    call :PrintRed "https://github.com/ValdikSS/GoodbyeDPI/issues/541#issuecomment-2661670982"
) else (
    call :PrintGreen "Intel Connectivity check passed"
)
echo:

:: Check Point
set "checkpointFound=0"
sc query | findstr /I "TracSrvWrapper" > nul
if %errorlevel%==0 (
    set "checkpointFound=1"
)

sc query | findstr /I "EPWD" > nul
if %errorlevel%==0 (
    set "checkpointFound=1"
)

if %checkpointFound%==1 (
    call :PrintRed "[X] Check Point services found. Check Point conflicts with zapret"
    call :PrintRed "Try to uninstall Check Point"
) else (
    call :PrintGreen "Check Point check passed"
)
echo:

:: SmartByte
sc query | findstr /I "SmartByte" > nul
if %errorlevel%==0 (
    call :PrintRed "[X] SmartByte services found. SmartByte conflicts with zapret"
    call :PrintRed "Try to uninstall or disable SmartByte through services.msc"
) else (
    call :PrintGreen "SmartByte check passed"
)
echo:

:: WinDivert64.sys file
set "BIN_PATH=%~dp0bin\"
if not exist "%BIN_PATH%\*.sys" (
    call :PrintRed "WinDivert64.sys file NOT found."
    echo:
)

:: VPN
set "VPN_SERVICES="
sc query | findstr /I "VPN" > nul
if %errorlevel%==0 (
    for /f "tokens=2 delims=:" %%A in ('sc query ^| findstr /I "VPN"') do (
        call :service_diagnostics_vpn_append "%%A"
    )
    call :service_diagnostics_vpn_found
) else (
    call :PrintGreen "VPN check passed"
)
goto :service_diagnostics_vpn_finished
:service_diagnostics_vpn_append
	if not defined VPN_SERVICES (
		set "VPN_SERVICES=%VPN_SERVICES%%~1"
	) else (
		set "VPN_SERVICES=%VPN_SERVICES%,%~1"
	)
	exit /b 0
:service_diagnostics_vpn_found
	call :PrintYellow "[?] VPN services found:%VPN_SERVICES%. Some VPNs can conflict with zapret"
    call :PrintYellow "Make sure that all VPNs are disabled"
	exit /b 0
:service_diagnostics_vpn_finished
echo:

:: DNS
set "dohfound=0"
for /f "delims=" %%a in ('powershell -NoProfile -Command "Get-ChildItem -Recurse -Path 'HKLM:System\CurrentControlSet\Services\Dnscache\InterfaceSpecificParameters\' | Get-ItemProperty | Where-Object { $_.DohFlags -gt 0 } | Measure-Object | Select-Object -ExpandProperty Count"') do (
    if %%a gtr 0 (
        set "dohfound=1"
    )
)
if %dohfound%==0 (
    call :PrintYellow "[?] Make sure you have configured secure DNS in a browser with some non-default DNS service provider,"
    call :PrintYellow "If you use Windows 11 you can configure encrypted DNS in the Settings to hide this warning"
) else (
    call :PrintGreen "Secure DNS check passed"
)
echo:

:: Hosts file check
set "hostsFile=%SystemRoot%\System32\drivers\etc\hosts"
set "yt_found=0"
if not exist "%hostsFile%" (
	goto :service_diagnostics_skip_check_hostfile
)
>nul 2>&1 findstr /I "youtube.com" "%hostsFile%" && set "yt_found=1"
>nul 2>&1 findstr /I "youtu.be" "%hostsFile%" && set "yt_found=1"
if %yt_found%==1 (
	call :PrintYellow "[?] Your hosts file contains entries for youtube.com or youtu.be. This may cause problems with YouTube access"
)
:service_diagnostics_skip_check_hostfile

:: WinDivert conflict
tasklist /FI "IMAGENAME eq winws.exe" | find /I "winws.exe" > nul
set "winws_running=%errorlevel%"

sc query "WinDivert" | findstr /I "RUNNING STOP_PENDING" > nul
set "windivert_running=%errorlevel%"

if %winws_running% neq 0 if %windivert_running%==0 (
    call :PrintYellow "[?] winws.exe is not running but WinDivert service is active. Attempting to delete WinDivert..."
    
    net stop "WinDivert" >nul 2>&1
    sc delete "WinDivert" >nul 2>&1
)
sc query "WinDivert" >nul 2>&1
if %winws_running% neq 0 if %windivert_running%==0 (
    if %errorlevel%==0 (
        call :PrintRed "[X] Failed to delete WinDivert. Checking for conflicting services..."
	)
) else (
	call :PrintGreen "WinDivert successfully removed"
	goto :service_diagnostics_WinDivert_conflict_finished
)
set "conflicting_services=GoodbyeDPI"
set "found_conflict=0"
for %%s in (%conflicting_services%) do (
	call :service_diagnostics_WinDivert_conflicting_stopping "%%s"
)

goto :service_diagnostics_WinDivert_conflicting_stopping_finished
:service_diagnostics_WinDivert_conflicting_stopping
	sc query "%~1" >nul 2>&1
	if not %errorlevel%==0 (
		exit /b 0
	)
	call :PrintYellow "[?] Found conflicting service: %~1. Stopping and removing..."
	net stop "%~1" >nul 2>&1
	sc delete "%~1" >nul 2>&1
	if %errorlevel%==0 (
		call :PrintGreen "Successfully removed service: %~1"
	) else (
		call :PrintRed "[X] Failed to remove service: %~1"
	)
	set "found_conflict=1"
	exit /b 0
:service_diagnostics_WinDivert_conflicting_stopping_finished

if %found_conflict%==0 (
	call :PrintRed "[X] No conflicting services found. Check manually if any other bypass is using WinDivert."
	goto :service_diagnostics_WinDivert_conflict_finished
)

call :PrintYellow "[?] Attempting to delete WinDivert again..."
net stop "WinDivert" >nul 2>&1
sc delete "WinDivert" >nul 2>&1
sc query "WinDivert" >nul 2>&1
if %errorlevel% neq 0 (
	call :PrintGreen "WinDivert successfully deleted after removing conflicting services"
) else (
	call :PrintRed "[X] WinDivert still cannot be deleted. Check manually if any other bypass is using WinDivert."
)
:service_diagnostics_WinDivert_conflict_finished
echo:

:: Conflicting bypasses
set "conflicting_services=GoodbyeDPI discordfix_zapret winws1 winws2"
set "found_any_conflict=0"
set "found_conflicts="

for %%s in (%conflicting_services%) do (
	call :service_diagnostics_conflicting_bypasses_append_conflict "%%s"
)
goto :service_diagnostics_conflicting_bypasses_append_conflict_finished
:service_diagnostics_conflicting_bypasses_append_conflict
    sc query "%~1" >nul 2>&1
    if %errorlevel%==0 (
        if "%found_conflicts%"=="" (
			set "found_conflicts=%~1"
		) else (
			set "found_conflicts=%found_conflicts% %~1"
		)
        set "found_any_conflict=1"
    )
	exit /b 0
:service_diagnostics_conflicting_bypasses_append_conflict_finished
    
if not "%found_any_conflict%"=="1" (
	goto :service_diagnostics_conflicting_bypasses_stopping_finished
)
call :PrintRed "[X] Conflicting bypass services found: %found_conflicts%"
set "CHOICE="
set /p "CHOICE=Do you want to remove these conflicting services? (Y/N) (default: N) "

if "%CHOICE%"=="" set "CHOICE=N"
if /i "%CHOICE%"=="Y" (
	for %%s in (%found_conflicts%) do (
		call :PrintYellow "Stopping and removing service: %%s"
		call :service_diagnostics_conflicting_bypasses_stopping "%%s"
	)

	net stop "WinDivert" >nul 2>&1
	sc delete "WinDivert" >nul 2>&1
	net stop "WinDivert14" >nul 2>&1
	sc delete "WinDivert14" >nul 2>&1
)
goto :service_diagnostics_conflicting_bypasses_stopping_finished
:service_diagnostics_conflicting_bypasses_stopping
	net stop "%~1" >nul 2>&1
	sc delete "%~1" >nul 2>&1
	if %errorlevel%==0 (
		call :PrintGreen "Successfully removed service: %~1"
	) else (
		call :PrintRed "[X] Failed to remove service: %~1"
	)
	exit /b 0
:service_diagnostics_conflicting_bypasses_stopping_finished
echo:

:: Discord cache clearing
set "discordFound=0"
set "CHOICE="
set /p "CHOICE=Do you want to clear the Discord and Discord PTB cache? (Y/N) (default: Y) "
if "%CHOICE%"=="" set "CHOICE=Y"
if "%CHOICE%"=="y" set "CHOICE=Y"

if /i not "%CHOICE%"=="Y" (
	goto :service_diagnostics_discord_cache_clearing_finished
)
if exist "%APPDATA%\discord\" (
	set "discordFound=1"
	call :clear_discord_cache "Discord.exe" "Discord" "%APPDATA%\discord"
)
if exist "%APPDATA%\discordptb\" (
	set "discordFound=1"
	call :clear_discord_cache "DiscordPTB.exe" "Discord PTB" "%APPDATA%\discordptb"
)
if %discordFound% equ 0 call :PrintRed "Discord and Discord PTB were not found"
:service_diagnostics_discord_cache_clearing_finished
set "discordFound="
echo:

pause
goto menu


:: GAME SWITCH ========================
:game_switch_status
chcp 437 > nul

set "gameFlagFile=%~dp0utils\game_filter.enabled"

if not exist "%gameFlagFile%" (
    set "GameFilterStatus=disabled"
    set "GameFilter=12"
    set "GameFilterTCP=12"
    set "GameFilterUDP=12"
    exit /b
)

set "GameFilterMode="
for /f "usebackq delims=" %%A in ("%gameFlagFile%") do (
    if not defined GameFilterMode set "GameFilterMode=%%A"
)

if /i "%GameFilterMode%"=="all" (
    set "GameFilterStatus=enabled (TCP and UDP)"
    set "GameFilter=1024-65535"
    set "GameFilterTCP=1024-65535"
    set "GameFilterUDP=1024-65535"
) else if /i "%GameFilterMode%"=="tcp" (
    set "GameFilterStatus=enabled (TCP)"
    set "GameFilter=1024-65535"
    set "GameFilterTCP=1024-65535"
    set "GameFilterUDP=12"
) else (
    set "GameFilterStatus=enabled (UDP)"
    set "GameFilter=1024-65535"
    set "GameFilterTCP=12"
    set "GameFilterUDP=1024-65535"
)
exit /b


:game_switch
chcp 437 > nul
cls

echo Select game filter mode:
echo   0. Disable
echo   1. TCP and UDP
echo   2. TCP only
echo   3. UDP only
echo.
set "GameFilterChoice=0"
set /p "GameFilterChoice=Select option (0-3, default: 0): "
if "%GameFilterChoice%"=="" set "GameFilterChoice=0"

if "%GameFilterChoice%"=="0" (
    if exist "%gameFlagFile%" (
        del /f /q "%gameFlagFile%"
    ) else (
        goto menu
    )
) else if "%GameFilterChoice%"=="1" (
    echo all>"%gameFlagFile%"
) else if "%GameFilterChoice%"=="2" (
    echo tcp>"%gameFlagFile%"
) else if "%GameFilterChoice%"=="3" (
    echo udp>"%gameFlagFile%"
) else (
    echo Invalid choice, exiting...
    pause
    goto menu
)

call :PrintYellow "Restart the zapret to apply the changes"
pause
goto menu


:: CHECK UPDATES SWITCH =================
:check_updates_switch_status
chcp 437 > nul

set "checkUpdatesFlag=%~dp0utils\check_updates.enabled"

if exist "%checkUpdatesFlag%" (
    set "CheckUpdatesStatus=enabled"
) else (
    set "CheckUpdatesStatus=disabled"
)
exit /b


:check_updates_switch
chcp 437 > nul
cls

if not exist "%checkUpdatesFlag%" (
    echo Enabling check updates...
    echo ENABLED > "%checkUpdatesFlag%"
) else (
    echo Disabling check updates...
    del /f /q "%checkUpdatesFlag%"
)

pause
goto menu


:: REPLACE ACTIVE FAKES =================
:replace_active_fakes
chcp 437 > nul
cls

set "BIN_PATH=%~dp0bin\"
set "fake_count=0"
set "fake_type="
set "fake_number="
set "discord_hash="
set "game_hash="
set "current_discord_fake=(not found)"
set "current_game_fake=(not found)"

if not exist "%BIN_PATH%" (
    echo Error: bin folder not found.
    pause
    goto menu
)

pushd "%BIN_PATH%"
for /f "tokens=1,2,3 delims=|" %%A in ('powershell -NoProfile -Command "foreach ($item in @(@{Name='ACTIVE_DISCORD_UDP.bin'; Label='ACTIVE_DISCORD'},@{Name='ACTIVE_GAME_UDP.bin'; Label='ACTIVE_GAME'})) { if (Test-Path -LiteralPath $item.Name) { Write-Output ($item.Label + [char]124 + $item.Label + [char]124 + (Get-FileHash -LiteralPath $item.Name -Algorithm SHA256).Hash) } }; $files = @(Get-ChildItem -LiteralPath . -File -Filter '*.bin'); foreach ($file in $files) { if ($file.BaseName -notlike 'ACTIVE_*') { Write-Output ('FAKE' + [char]124 + $file.BaseName + [char]124 + (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash) } }"') do (
    call :replace_active_fakes_process_fake_info "%%A" "%%B" "%%C"
)
popd
goto :replace_active_fakes_process_bin_finished

:replace_active_fakes_process_fake_info
	if "%~1"=="ACTIVE_DISCORD" (
		set "discord_hash=%~3"
	) else if "%~1"=="ACTIVE_GAME" (
		set "game_hash=%~3"
	) else if "%~1"=="FAKE" (
		call :replace_active_fakes_process_fake_info_add_to_array "%%~1" "%%~2" "%%~3"
	)
	exit /b 0

:replace_active_fakes_process_fake_info_add_to_array
    set /a fake_count+=1
    call set "fake_file%fake_count%=%BIN_PATH%%~2.bin"
    call set "fake_name%fake_count%=%~2"
    call set "fake_hash%fake_count%=%~3"
	exit /b 0
:replace_active_fakes_process_bin_finished

if %fake_count% EQU 0 (
    echo No .bin files were found in the bin folder.
    pause
    goto menu
)

for /l %%N in (1,1,%fake_count%) do (
    call :replace_active_fakes_match_fakes %%N
)
goto :replace_active_fakes_match_fakes_finished

:replace_active_fakes_match_fakes
	set "cur_h="
	call set "cur_h=%%fake_hash%1%%"
	call set "cur_n=%%fake_name%1%%"
	if defined discord_hash if /i "%cur_h%"=="%discord_hash%" set "current_discord_fake=%cur_n%"
	if defined game_hash if /i "%cur_h%"=="%game_hash%" set "current_game_fake=%cur_n%"
	exit /b 0
:replace_active_fakes_match_fakes_finished

:replace_active_fakes_prompt
echo.
echo Enter the fake type number and the fake file number to replace it with.
echo Example: 1 4 (replaces Discord UDP with fake file under number 4)
echo          2 1 (replaces GameFilter UDP with fake file under number 1)
echo.
echo Press ENTER or 0 to return.
echo.
echo   ----------------------------------------
echo.
echo Fake types:
echo   1. Discord UDP     (current: %current_discord_fake%)
echo   2. GameFilter UDP  (current: %current_game_fake%)
echo.
echo Fake files:
for /l %%N in (1,1,%fake_count%) do (
    call echo   %%N. %%fake_name%%N%%
)
echo.

set "replace_choice="
set /p "replace_choice=Enter choice: "
if not defined replace_choice goto menu
if "%replace_choice%"=="0" goto menu

set "active_file="
set "fake_type="
set "fake_number="
for /f "tokens=1,2" %%A in ("%replace_choice%") do (
    set "fake_type=%%A"
    set "fake_number=%%B"
)

if "%fake_type%"=="1" (
    set "active_file=%BIN_PATH%ACTIVE_DISCORD_UDP.bin"
) else if "%fake_type%"=="2" (
    set "active_file=%BIN_PATH%ACTIVE_GAME_UDP.bin"
) else (
    echo Invalid fake type.
    pause
    cls
    goto replace_active_fakes_prompt
)

call set "new_fake_path=%%fake_file%fake_number%%%"
call set "new_fake_name=%%fake_name%fake_number%%%"
if not defined new_fake_path (
    echo Invalid fake file number.
    pause
    cls
    goto replace_active_fakes_prompt
)

del /f /q "%active_file%" >nul 2>&1
copy /y "%new_fake_path%" "%active_file%" >nul
if errorlevel 1 (
    echo Failed to replace the active fake file.
) else (
    echo Active fake file replaced successfully.
    if "%fake_type%"=="1" set "current_discord_fake=%new_fake_name%"
    if "%fake_type%"=="2" set "current_game_fake=%new_fake_name%"
)
pause
cls
goto replace_active_fakes_prompt


:: IPSET SWITCH =======================
:ipset_switch_status
chcp 437 > nul

set "listFile=%~dp0lists\ipset-all.txt"
set "lineCount=0"
for /f %%i in ('type "%listFile%" 2^>nul ^| find /c /v ""') do set "lineCount=%%i"

if %lineCount%==0 (
    set "IPsetStatus=any"
	exit /b 0
)

findstr /C:"203.0.113.113/32" "%listFile%" >nul
if %errorlevel%==0 (
	set "IPsetStatus=none"
) else (
	set "IPsetStatus=loaded"
)
exit /b


:ipset_switch
chcp 437 > nul
cls

set "listFile=%~dp0lists\ipset-all.txt"
set "backupFile=%listFile%.backup"

if "%IPsetStatus%"=="loaded" (
    echo Switching to none mode...
    
    if not exist "%backupFile%" (
        ren "%listFile%" "ipset-all.txt.backup"
    ) else (
        del /f /q "%backupFile%"
        ren "%listFile%" "ipset-all.txt.backup"
    )
    
    >"%listFile%" (
        echo 203.0.113.113/32
    )
    
) else if "%IPsetStatus%"=="none" (
    echo Switching to any mode...
    
    >"%listFile%" (
        rem Creating empty file
    )
    
) else if "%IPsetStatus%"=="any" (
    echo Switching to loaded mode...
    
    if exist "%backupFile%" (
        del /f /q "%listFile%"
        ren "%backupFile%" "ipset-all.txt"
    ) else (
        echo Error: no backup to restore. Update list from service menu first
        pause
        goto menu
    )
    
)

pause
goto menu


:: IPSET UPDATE =======================
:ipset_update
chcp 437 > nul
cls

set "listFile=%~dp0lists\ipset-all.txt"
set "url=https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/refs/heads/main/.service/ipset-service.txt"

echo Updating ipset-all...

if not exist "%SystemRoot%\System32\curl.exe" (
    powershell -NoProfile -Command ^
        "$url = '%url%';" ^
        "$out = '%listFile%';" ^
        "$dir = Split-Path -Parent $out;" ^
        "if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null };" ^
        "$res = Invoke-WebRequest -Uri $url -TimeoutSec 10 -UseBasicParsing;" ^
        "if ($res.StatusCode -eq 200) { $res.Content | Out-File -FilePath $out -Encoding UTF8 } else { exit 1 }"
		goto :ipset_update_finished
)

curl --version | find "libcurl/7"
if %errorlevel%==0 (
	curl --ssl-no-revoke -L -o "%listFile%" "%url%"
) else (
	curl --ssl-revoke-best-effort -L -o "%listFile%" "%url%"
)
:ipset_update_finished
echo Finished

pause
goto menu


:: HOSTS UPDATE =======================
:hosts_update
chcp 437 > nul
cls

set "hostsFile=%SystemRoot%\System32\drivers\etc\hosts"
set "hostsUrl=https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/refs/heads/main/.service/hosts"
set "tempFile=%TEMP%\zapret_hosts.txt"
set "needsUpdate=0"

set "cacheBuster=%RANDOM%%RANDOM%%RANDOM%"
set "requestUrl=%hostsUrl%?t=%cacheBuster%"

echo Checking hosts file...

if exist "%SystemRoot%\System32\curl.exe" (
    curl -L -s -o "%tempFile%" "%requestUrl%"
) else (
    powershell -NoProfile -Command ^
        "$url = '%requestUrl%';" ^
        "$out = '%tempFile%';" ^
        "$res = Invoke-WebRequest -Uri $url -TimeoutSec 10 -UseBasicParsing;" ^
        "if ($res.StatusCode -eq 200) { $res.Content | Out-File -FilePath $out -Encoding UTF8 } else { exit 1 }"
)
if not exist "%tempFile%" (
    call :PrintRed "Failed to download hosts file from repository"
    call :PrintYellow "Copy hosts file manually from %hostsUrl%"
    pause
    goto menu
)

set "firstLine="
set "lastLine="
for /f "usebackq delims=" %%a in ("%tempFile%") do (
    if not defined firstLine (
        set "firstLine=%%a"
    )
    set "lastLine=%%a"
)

findstr /C:"%firstLine%" "%hostsFile%" >nul 2>&1
if %errorlevel% neq 0 (
    echo First line from repository not found in hosts file
    set "needsUpdate=1"
)

findstr /C:"%lastLine%" "%hostsFile%" >nul 2>&1
if %errorlevel% neq 0 (
    echo Last line from repository not found in hosts file
    set "needsUpdate=1"
)

if "%needsUpdate%"=="1" (
    echo:
    call :PrintYellow "Hosts file needs to be updated"
    call :PrintYellow "Please manually copy the content from the downloaded file to your hosts file"
    
    start notepad "%tempFile%"
    explorer /select,"%hostsFile%"
) else (
    call :PrintGreen "Hosts file is up to date"
    if exist "%tempFile%" del /f /q "%tempFile%"
)

echo:
pause
goto menu


:: RUN TESTS =============================
:run_tests
chcp 437 >nul
cls

:: Require PowerShell 3.0+
powershell -NoProfile -Command "if ($PSVersionTable -and $PSVersionTable.PSVersion -and $PSVersionTable.PSVersion.Major -ge 3) { exit 0 } else { exit 1 }" >nul 2>&1
if %errorLevel% neq 0 (
    echo PowerShell 3.0 or newer is required.
    echo Please upgrade PowerShell and rerun this script.
    echo.
    pause
    goto menu
)

echo Starting configuration tests in PowerShell window...
echo.
start "" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0utils\test zapret.ps1"
pause
goto menu


:: Get strategy name
:get_strategy_name
set "CurrentStrategy="
for /f "tokens=2*" %%A in ('reg query "HKLM\System\CurrentControlSet\Services\zapret" /v zapret-discord-youtube 2^>nul') do set "CurrentStrategy=Strategy: %%B"
exit /b


:: Utility functions

:clear_discord_cache
set "discordProcess=%~1"
set "discordName=%~2"
set "discordCacheDir=%~3"

tasklist /FI "IMAGENAME eq %discordProcess%" 2>nul | findstr /I /C:"%discordProcess%" >nul
if not %errorlevel% equ 0 (
	goto :clear_discord_cache_app_closed
)
echo %discordName% is running, closing...
taskkill /IM "%discordProcess%" /F >nul 2>&1
if %errorlevel% equ 0 (
	call :PrintGreen "%discordName% was successfully closed"
) else (
	call :PrintRed "Unable to close %discordName%"
)
:clear_discord_cache_app_closed

if exist "%discordCacheDir%\" (
    for %%d in ("Cache" "Code Cache" "GPUCache") do (
		call :clear_discord_cache_delete_path "%%~d"
    )
)

goto :clear_discord_cache_delete_path_finished
:clear_discord_cache_delete_path
	set "dirPath=%discordCacheDir%\%~1"
	if exist "%dirPath%\" (
		rd /s /q "%dirPath%" >nul 2>&1
		if exist "%dirPath%\" (
			call :PrintRed "Failed to delete %dirPath%"
		) else (
			call :PrintGreen "Successfully deleted %dirPath%"
		)
	) else (
		call :PrintRed "%dirPath% does not exist"
	)
	exit /b 0
:clear_discord_cache_delete_path_finished
exit /b

:PrintGreen
powershell -NoProfile -Command "Write-Host \"%~1\" -ForegroundColor Green"
exit /b

:PrintRed
powershell -NoProfile -Command "Write-Host \"%~1\" -ForegroundColor Red"
exit /b

:PrintYellow
powershell -NoProfile -Command "Write-Host \"%~1\" -ForegroundColor Yellow"
exit /b

:check_command
where %1 >nul 2>&1
if %errorLevel% neq 0 (
    echo [ERROR] %1 not found in PATH
    echo Fix your PATH variable with instructions here https://github.com/Flowseal/zapret-discord-youtube/issues/7490
    pause
    exit /b 1
)
exit /b 0

:check_extracted
set "extracted=1"

if not exist "%~dp0bin\" set "extracted=0"

if "%extracted%"=="0" (
    echo Zapret must be extracted from archive first or bin folder not found for some reason
    pause
    exit
)
exit /b 0
