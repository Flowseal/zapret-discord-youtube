@echo off
set "LOCAL_VERSION=1.8.9"

:: External commands
if "%~1"=="status_zapret" (
	call :test_service zapret soft
	call :tcp_enable
	exit /b
)

if "%~1"=="check_updates" (
	if not "%~2"=="soft" (
		start /b service check_updates soft
	) else (
		call :service_check_updates soft
	)
	exit /b
)

net session >nul 2>&1
if %errorlevel% neq 0 (
	echo Requesting admin rights...
	powershell -Command "Start-Process 'cmd.exe' -ArgumentList '/c \"\"%~f0\" %*\"' -Verb RunAs"
	exit /b
)

call "%~dp0config.bat"

:: MENU ================================
setlocal EnableDelayedExpansion
:menu
cls
set "menu_choice=null"
echo =========  v!LOCAL_VERSION!  =========
echo 1. Install Service
echo 2. Remove Services
echo 3. Check Service Status
echo 4. Run Diagnostics
echo 5. Check Updates
echo 6. Update ipset list
echo 0. Exit
set /p menu_choice=Enter choice (0-6): 

if "%menu_choice%"=="1" goto service_install
if "%menu_choice%"=="2" goto service_remove
if "%menu_choice%"=="3" goto service_status
if "%menu_choice%"=="4" goto service_diagnostics
if "%menu_choice%"=="5" goto service_check_updates
if "%menu_choice%"=="6" goto ipset_update
if "%menu_choice%"=="0" exit /b
goto menu

:: TCP ENABLE ==========================
:tcp_enable
netsh interface tcp show global | findstr /i "timestamps" | findstr /i "enabled" > nul || netsh interface tcp set global timestamps=enabled > nul 2>&1
exit /b


:: STATUS ==============================
:service_status
cls
chcp 437 > nul

sc query "%SERVICE_NAME%" >nul 2>&1
if !errorlevel!==0 (
    for /f "tokens=2*" %%A in ('reg query "HKLM\System\CurrentControlSet\Services\%SERVICE_NAME%" /v zapret-discord-youtube 2^>nul') do echo Service strategy installed from "%%B"
)

call :test_service "%SERVICE_NAME%"
call :test_service "Monkey"
echo:

tasklist /FI "IMAGENAME eq winws.exe" | find /I "winws.exe" > nul
if !errorlevel!==0 (
	call :PrintGreen "Bypass is ACTIVE"
) else (
	call :PrintRed "Bypass NOT FOUND"
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
    call :PrintYellow "!ServiceName! is STOP_PENDING, that may be caused by a conflict with another bypass. Run Diagnostics to try to fix conflicts"
) else if not "%~2"=="soft" (
    echo "%ServiceName%" service is NOT running.
)

exit /b


:: REMOVE ==============================
:service_remove
cls
chcp 65001 > nul

sc query "!SERVICE_NAME!" >nul 2>&1
if !errorlevel!==0 (
    net stop %SERVICE_NAME%
    sc delete %SERVICE_NAME%
) else (
    echo Service "%SERVICE_NAME%" is not installed.
)

tasklist /FI "IMAGENAME eq %IMAGE_NAME%" | find /I "%IMAGE_NAME%" > nul
if !errorlevel!==0 (
    taskkill /IM %IMAGE_NAME% /F > nul
)

sc query "%DRIVER_NAME%" >nul 2>&1
if !errorlevel!==0 (
    net stop "%DRIVER_NAME%"

    sc query "%DRIVER_NAME%" >nul 2>&1
    if !errorlevel!==0 (
        sc delete "%DRIVER_NAME%"
    )
)
net stop "WinDivert14" >nul 2>&1
sc delete "WinDivert14" >nul 2>&1

pause
goto menu


:: INSTALL =============================
:service_install
cls
chcp 65001 > nul

:: Main
cd /d "%ZAPRET_BASE%"

:: Searching for .bat files in current folder, except files that start with "service"
echo Pick one of the options:
set "count=0"
for %%f in (*.bat) do (
	set "filename=%%~nxf"
	if /i not "!filename:~0,7!"=="service" if /i not "!filename:~0,17!"=="cloudflare_switch" if /i not "!filename:~0,6!"=="config" if /i not "!filename:~0,9!"=="functions" if /i not "!filename:~0,7!"=="wrapper" (
		set /a count+=1
		echo !count!. %%f
		set "file!count!=%%f"
	)
)

:: Choosing file
set "choice="
set /p "choice=Input file index (number): "
if "!choice!"=="" goto :eof

set "selectedFile=!file%choice%!"
if not defined selectedFile (
	echo Invalid choice, exiting...
	pause
	goto menu
)

:: Creating service
call :tcp_enable

net stop %SERVICE_NAME% >nul 2>&1
sc delete %SERVICE_NAME% >nul 2>&1
call "%selectedFile%" "install"
sc config %SERVICE_NAME% DisplayName= "%SERVICE_DISPLAY_NAME%"
sc description %SERVICE_NAME% "%SERVICE_DESCRIPTION%"
sc start %SERVICE_NAME%
for %%F in ("!file%choice%!") do (
	set "filename=%%~nF"
)
reg add "HKLM\System\CurrentControlSet\Services\%SERVICE_NAME%" /v "zapret-discord-youtube" /t REG_SZ /d "!filename!" /f

pause
goto menu


:: CHECK UPDATES =======================
:service_check_updates
chcp 437 > nul
cls

:: Get the latest version from GitHub
for /f "delims=" %%A in ('powershell -command "(Invoke-WebRequest -Uri \"%GITHUB_VERSION_URL%\" -Headers @{\"Cache-Control\"=\"no-cache\"} -TimeoutSec 5).Content.Trim()" 2^>nul') do set "GITHUB_VERSION=%%A"

:: Error handling
if not defined GITHUB_VERSION (
	echo Warning: failed to fetch the latest version. Check your internet connection. This warning does not affect the operation of zapret
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

set "CHOICE="
set /p "CHOICE=Do you want to automatically download the new version? (Y/N) (default: Y) "
if "%CHOICE%"=="" set "CHOICE=Y"
if /i "%CHOICE%"=="y" set "CHOICE=Y"

if /i "%CHOICE%"=="Y" (
	echo Opening the download page...
	start "" "%GITHUB_DOWNLOAD_URL%%GITHUB_VERSION%.rar"
)


if "%1"=="soft" exit 
pause
goto menu


:: DIAGNOSTICS =========================
:service_diagnostics
chcp 437 > nul
cls

:: Base Filtering Engine
sc query BFE | findstr /I "RUNNING" > nul
if !errorlevel!==0 (
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

if !proxyEnabled!==1 (
    for /f "tokens=2*" %%A in ('reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyServer 2^>nul ^| findstr /i "ProxyServer"') do (
        set "proxyServer=%%B"
    )
    
    call :PrintYellow "[?] System proxy is enabled: !proxyServer!"
    call :PrintYellow "Make sure it's valid or disable it if you don't use a proxy"
) else (
    call :PrintGreen "Proxy check passed"
)
echo:

:: TCP timestamps check
netsh interface tcp show global | findstr /i "timestamps" | findstr /i "enabled" > nul
if !errorlevel!==0 (
    call :PrintGreen "TCP timestamps check passed"
) else (
    call :PrintYellow "[?] TCP timestamps are disabled. Enabling timestamps..."
    netsh interface tcp set global timestamps=enabled > nul 2>&1
    if !errorlevel!==0 (
        call :PrintGreen "TCP timestamps successfully enabled"
    ) else (
        call :PrintRed "[X] Failed to enable TCP timestamps"
    )
)
echo:

:: AdguardSvc.exe
tasklist /FI "IMAGENAME eq AdguardSvc.exe" | find /I "AdguardSvc.exe" > nul
if !errorlevel!==0 (
	call :PrintRed "[X] Adguard process found. Adguard may cause problems with Discord"
	call :PrintRed "https://github.com/Flowseal/zapret-discord-youtube/issues/417"
) else (
	call :PrintGreen "Adguard check passed"
)
echo:

:: Killer
sc query | findstr /I "Killer" > nul
if !errorlevel!==0 (
	call :PrintRed "[X] Killer services found. Killer conflicts with zapret"
	call :PrintRed "https://github.com/Flowseal/zapret-discord-youtube/issues/2512#issuecomment-2821119513"
) else (
	call :PrintGreen "Killer check passed"
)
echo:

:: Intel Connectivity Network Service
sc query | findstr /I "Intel" | findstr /I "Connectivity" | findstr /I "Network" > nul
if !errorlevel!==0 (
	call :PrintRed "[X] Intel Connectivity Network Service found. It conflicts with zapret"
	call :PrintRed "https://github.com/ValdikSS/GoodbyeDPI/issues/541#issuecomment-2661670982"
) else (
	call :PrintGreen "Intel Connectivity check passed"
)
echo:

:: Check Point
set "checkpointFound=0"
sc query | findstr /I "TracSrvWrapper" > nul
if !errorlevel!==0 (
	set "checkpointFound=1"
)

sc query | findstr /I "EPWD" > nul
if !errorlevel!==0 (
	set "checkpointFound=1"
)

if !checkpointFound!==1 (
	call :PrintRed "[X] Check Point services found. Check Point conflicts with zapret"
	call :PrintRed "Try to uninstall Check Point"
) else (
	call :PrintGreen "Check Point check passed"
)
echo:

:: SmartByte
sc query | findstr /I "SmartByte" > nul
if !errorlevel!==0 (
	call :PrintRed "[X] SmartByte services found. SmartByte conflicts with zapret"
	call :PrintRed "Try to uninstall or disable SmartByte through services.msc"
) else (
	call :PrintGreen "SmartByte check passed"
)
echo:

:: VPN
sc query | findstr /I "VPN" > nul
if !errorlevel!==0 (
	call :PrintYellow "[?] Some VPN services found. Some VPNs can conflict with zapret"
	call :PrintYellow "Make sure that all VPNs are disabled"
) else (
	call :PrintGreen "VPN check passed"
)
echo:

:: DNS
set "dohfound=0"
for /f "delims=" %%a in ('powershell -Command "Get-ChildItem -Recurse -Path 'HKLM:System\CurrentControlSet\Services\Dnscache\InterfaceSpecificParameters\' | Get-ItemProperty | Where-Object { $_.DohFlags -gt 0 } | Measure-Object | Select-Object -ExpandProperty Count"') do (
    if %%a gtr 0 (
        set "dohfound=1"
    )
)
if !dohfound!==0 (
    call :PrintYellow "[?] Make sure you have configured secure DNS in a browser with some non-default DNS service provider,"
    call :PrintYellow "If you use Windows 11 you can configure encrypted DNS in the Settings to hide this warning"
) else (
    call :PrintGreen "Secure DNS check passed"
)
echo:

:: WinDivert conflict
tasklist /FI "IMAGENAME eq %IMAGE_NAME%" | find /I "%IMAGE_NAME%" > nul
set "winws_running=!errorlevel!"

sc query "%DRIVER_NAME%" | findstr /I "RUNNING STOP_PENDING" > nul
set "windivert_running=!errorlevel!"

if !winws_running! neq 0 if !windivert_running!==0 (
    call :PrintYellow "[?] winws.exe is not running but %DRIVER_NAME% service is active. Attempting to delete %DRIVER_NAME%..."
    
    net stop "%DRIVER_NAME%" >nul 2>&1
    sc delete "%DRIVER_NAME%" >nul 2>&1
    sc query "%DRIVER_NAME%" >nul 2>&1
    if !errorlevel!==0 (
        call :PrintRed "[X] Failed to delete %DRIVER_NAME%. Checking for conflicting services..."
        
        set "conflicting_services=GoodbyeDPI"
        set "found_conflict=0"
        
        for %%s in (!conflicting_services!) do (
            sc query "%%s" >nul 2>&1
            if !errorlevel!==0 (
                call :PrintYellow "[?] Found conflicting service: %%s. Stopping and removing..."
                net stop "%%s" >nul 2>&1
                sc delete "%%s" >nul 2>&1
                if !errorlevel!==0 (
                    call :PrintGreen "Successfully removed service: %%s"
                ) else (
                    call :PrintRed "[X] Failed to remove service: %%s"
                )
                set "found_conflict=1"
            )
        )
        
        if !found_conflict!==0 (
            call :PrintRed "[X] No conflicting services found. Check manually if any other bypass is using %DRIVER_NAME%."
        ) else (
            call :PrintYellow "[?] Attempting to delete %DRIVER_NAME% again..."

            net stop "%DRIVER_NAME%" >nul 2>&1
            sc delete "%DRIVER_NAME%" >nul 2>&1
            sc query "%DRIVER_NAME%" >nul 2>&1
            if !errorlevel! neq 0 (
                call :PrintGreen "%DRIVER_NAME% successfully deleted after removing conflicting services"
            ) else (
                call :PrintRed "[X] %DRIVER_NAME% still cannot be deleted. Check manually if any other bypass is using %DRIVER_NAME%."
            )
        )
    ) else (
        call :PrintGreen "%DRIVER_NAME% successfully removed"
    )
    
    echo:
)

:: Conflicting bypasses
set "conflicting_services=GoodbyeDPI %CONFLICTING_SERVICES%"
set "found_any_conflict=0"
set "found_conflicts="

for %%s in (!conflicting_services!) do (
    sc query "%%s" >nul 2>&1
    if !errorlevel!==0 (
        if "!found_conflicts!"=="" (
            set "found_conflicts=%%s"
        ) else (
            set "found_conflicts=!found_conflicts! %%s"
        )
        set "found_any_conflict=1"
    )
)

if !found_any_conflict!==1 (
    call :PrintRed "[X] Conflicting bypass services found: !found_conflicts!"
    
    set "CHOICE="
    set /p "CHOICE=Do you want to remove these conflicting services? (Y/N) (default: N) "
    if "!CHOICE!"=="" set "CHOICE=N"
    if "!CHOICE!"=="y" set "CHOICE=Y"
    
    if /i "!CHOICE!"=="Y" (
        for %%s in (!found_conflicts!) do (
            call :PrintYellow "Stopping and removing service: %%s"
            net stop "%%s" >nul 2>&1
            sc delete "%%s" >nul 2>&1
            if !errorlevel!==0 (
                call :PrintGreen "Successfully removed service: %%s"
            ) else (
                call :PrintRed "[X] Failed to remove service: %%s"
            )
        )

        net stop "%DRIVER_NAME%" >nul 2>&1
        sc delete "%DRIVER_NAME%" >nul 2>&1
        net stop "WinDivert14" >nul 2>&1
        sc delete "WinDivert14" >nul 2>&1
    )
    
    echo:
)

:: Discord cache clearing
:: Updated, added removal of PTB and Canary versions. See https://github.com/Flowseal/zapret-discord-youtube/pull/4088
set "CHOICE="
set /p "CHOICE=Do you want to clear the Discord cache? (Y/N) (default: Y)  "
if "!CHOICE!"=="" set "CHOICE=Y"
if "!CHOICE!"=="y" set "CHOICE=Y"

if /i "!CHOICE!"=="Y" (
	::  Close Discord processes (Discord.exe, DiscordPTB.exe, DiscordCanary.exe)
	for %%i in ("Discord.exe" "DiscordPTB.exe" "DiscordCanary.exe") do (
		tasklist /FI "IMAGENAME eq %%i" | findstr /I "%%i" > nul
		if !errorlevel!==0 (
			echo %%i is running, closing...
			taskkill /IM %%i /F > nul
			if !errorlevel! == 0 (
				call :PrintGreen "%%i was successfully closed"
			) else (
				call :PrintRed "Unable to close %%i"
			)
		)
	)

	set "discordCacheDir=%appdata%\discord"
	set "discordPTBCacheDir=%appdata%\discordptb"
	set "discordCanaryCacheDir=%appdata%\discordcanary"

	for %%d in ("Cache" "Code Cache" "GPUCache") do (
		set "dirPath=!discordCacheDir!\%%~d"
		if exist "!dirPath!" (
			rd /s /q "!dirPath!"
			if !errorlevel!==0 (
				call :PrintGreen "Successfully deleted !dirPath!"
			) else (
				call :PrintRed "Failed to delete !dirPath!"
			)
		) else (
			call :PrintRed "!dirPath! does not exist"
		)
	)
	
	if exist "!discordPTBCacheDir!\" (
		echo Cleaning Discord PTB cache...
		for %%d in ("Cache" "Code Cache" "GPUCache") do (
			set "dirPath=!discordPTBCacheDir!\%%~d"
			if exist "!dirPath!" (
				rd /s /q "!dirPath!"
				if !errorlevel!==0 (
					call :PrintGreen "Successfully deleted !dirPath!"
				) else (
					call :PrintRed "Failed to delete !dirPath!"
				)
			) else (
				call :PrintRed "!dirPath! does not exist"
			)
		)
	)

	if exist "!discordCanaryCacheDir!\" (
		echo Cleaning Discord Canary cache...
		for %%d in ("Cache" "Code Cache" "GPUCache") do (
			set "dirPath=!discordCanaryCacheDir!\%%~d"
			if exist "!dirPath!" (
				rd /s /q "!dirPath!"
				if !errorlevel!==0 (
					call :PrintGreen "Successfully deleted !dirPath!"
				) else (
					call :PrintRed "Failed to delete !dirPath!"
				)
			) else (
				call :PrintRed "!dirPath! does not exist"
			)
		)
	)
)
echo:

pause
goto menu


:: IPSET UPDATE =======================
:ipset_update
chcp 437 > nul
cls

echo Updating ipset-all...

call "%FUNCTIONS_SCRIPT%" download_file "%IPSET_ALL_URL%" "%IPSET_ALL_FILE%"

echo Updating list-general...

call "%FUNCTIONS_SCRIPT%" download_file "%LIST_GENERAL_URL%" "%LIST_GENERAL_FILE%"

echo Finished.

pause
goto menu


:: Utility functions

:PrintGreen
powershell -Command "Write-Host \"%~1\" -ForegroundColor Green"
exit /b

:PrintRed
powershell -Command "Write-Host \"%~1\" -ForegroundColor Red"
exit /b

:PrintYellow
powershell -Command "Write-Host \"%~1\" -ForegroundColor Yellow"
exit /b
