@echo off
chcp 65001 > nul
cd /d "%~dp0"

:: Проверка прав администратора
if "%1"=="admin" (
    goto main
) else (
    powershell -NoProfile -Command "Start-Process 'cmd.exe' -ArgumentList '/c \"\"%~f0\" admin\"' -Verb RunAs"
    exit
)

:main
setlocal EnableDelayedExpansion
title ZAPRET SMART ROUTING SYSTEM

:: Инициализация путей
set "LISTS_PATH=%~dp0lists\"
set "F_DOM_GEN=!LISTS_PATH!list-general-user.txt"
set "F_DOM_EXC=!LISTS_PATH!list-exclude-user.txt"
set "F_IP_GEN=!LISTS_PATH!ipset-general-user.txt"
set "F_IP_EXC=!LISTS_PATH!ipset-exclude-user.txt"

if not exist "!LISTS_PATH!" mkdir "!LISTS_PATH!"
for %%F in ("!F_DOM_GEN!" "!F_DOM_EXC!" "!F_IP_GEN!" "!F_IP_EXC!") do (
    if not exist "%%~F" type nul > "%%~F"
)

:: MENU ================================
:menu
cls
echo.
echo   ZAPRET SMART ROUTING SYSTEM
echo   ----------------------------------------
echo.
echo   :: ROUTING (ADD)
echo      1. Smart Add to BYPASS       (Обход)
echo      2. Smart Add to EXCLUDE      (Исключения)
echo.
echo   :: MANAGEMENT (VIEW/EDIT/SEARCH)
echo      3. Manage BYPASS Lists       (Редактор обхода)
echo      4. Manage EXCLUDE Lists      (Редактор исключений)
echo      5. Inspect Resource          (Поиск домена/IP в списках)
echo.
echo   :: SYSTEM
echo      6. Apply changes             (Restart zapret service)
echo.
echo   ----------------------------------------
echo      0. Exit
echo.

set "menu_choice="
set /p menu_choice=   Select option (0-6): 

if "!menu_choice!"=="1" call :smart_add "GEN"
if "!menu_choice!"=="2" call :smart_add "EXC"
if "!menu_choice!"=="3" call :manage_ui "BYPASS" "!F_DOM_GEN!" "!F_IP_GEN!"
if "!menu_choice!"=="4" call :manage_ui "EXCLUDE" "!F_DOM_EXC!" "!F_IP_EXC!"
if "!menu_choice!"=="5" call :inspector
if "!menu_choice!"=="6" call :restart_zapret
if "!menu_choice!"=="0" exit /b
goto menu

:: SMART ADD & DNS RESOLVER ============
:smart_add
set "mode=%~1"
echo.
set "raw_input="
set /p "raw_input=   > Paste link, domain, IP or subnet: "
if "!raw_input!"=="" goto :eof

:: Очистка URL
set "val=!raw_input: =!"
set "val=!val:http://=!"
set "val=!val:https://=!"
set "val=!val:www.=!"
for /f "tokens=1 delims=/" %%a in ("!val!") do set "val=%%a"

echo !raw_input! | findstr /R "[0-9]/[0-9]" >nul
if !errorlevel!==0 for /f "tokens=1 delims= " %%a in ("!raw_input!") do set "val=%%a"

:: Определение типа
set "is_ip=1"
set "check_str=!val!"
for %%C in (0 1 2 3 4 5 6 7 8 9 . /) do set "check_str=!check_str:%%C=!"
if not "!check_str!"=="" set "is_ip=0"

:: Маршрутизация
if "!is_ip!"=="1" (
    set "type_name=IP/Subnet"
    if "!mode!"=="GEN" (set "t_file=!F_IP_GEN!" & set "c_file=!F_IP_EXC!")
    if "!mode!"=="EXC" (set "t_file=!F_IP_EXC!" & set "c_file=!F_IP_GEN!")
) else (
    set "type_name=Domain"
    if "!mode!"=="GEN" (set "t_file=!F_DOM_GEN!" & set "c_file=!F_DOM_EXC!")
    if "!mode!"=="EXC" (set "t_file=!F_DOM_EXC!" & set "c_file=!F_DOM_GEN!")
)

:: Проверки
findstr /x /i /c:"!val!" "!t_file!" >nul 2>&1
if !errorlevel!==0 (
    call :PrintYellow "   [~] !type_name! '!val!' already exists in this list."
    goto end_pause
)

findstr /x /i /c:"!val!" "!c_file!" >nul 2>&1
if !errorlevel!==0 (
    call :PrintRed "   [X] CONFLICT! '!val!' found in the opposite list!"
    call :PrintYellow "       Remove it from !c_file! first."
    goto end_pause
)

:: Запись
>>"!t_file!" echo !val!
call :PrintGreen "   [+] Successfully added: !val!"

:: KILLER FEATURE: DNS Deep-Resolve
if "!is_ip!"=="0" if "!mode!"=="GEN" (
    echo.
    call :PrintYellow "   [?] Do you want to resolve IP addresses for '!val!'?"
    call :PrintYellow "       This strongly helps if ISP blocks IPs directly. (Y/N)"
    set "dns_choice="
    set /p "dns_choice=   > "
    if /i "!dns_choice!"=="Y" (
        call :PrintYellow "   [*] Resolving..."
        for /f "delims=" %%I in ('powershell -NoProfile -Command "try { [System.Net.Dns]::GetHostAddresses('!val!') | Where-Object AddressFamily -eq 'InterNetwork' | ForEach-Object IPAddressToString } catch {}"') do (
            findstr /x /i /c:"%%I" "!F_IP_GEN!" >nul 2>&1
            if !errorlevel! neq 0 (
                >>"!F_IP_GEN!" echo %%I
                call :PrintGreen "       [+] IP Added: %%I (ipset-general-user)"
            ) else (
                call :PrintYellow "       [~] IP Exists: %%I"
            )
        )
    )
)
:end_pause
echo.
echo   Press any key to return...
pause >nul
goto :eof

:: DASHBOARD (CRUD) ====================
:manage_ui
set "ui_title=%~1"
set "ui_dom_file=%~2"
set "ui_ip_file=%~3"

:ui_loop
cls
echo.
echo   === MANAGE !ui_title! LISTS ===
echo.
echo   [ DOMAINS ]
call :list_content "!ui_dom_file!" "D"
echo.
echo   [ IP ADDRESSES ]
call :list_content "!ui_ip_file!" "I"
echo.
echo   ----------------------------------------
echo   Type ID to delete (e.g. D1, I3). Leave empty to go back.
set "del_choice="
set /p "del_choice=   > "
if "!del_choice!"=="" goto :eof

:: Очистка от пробелов (защита от опечаток)
set "del_choice=!del_choice: =!"
set "l_type=!del_choice:~0,1!"
set "l_num=!del_choice:~1!"

if /i "!l_type!"=="D" call :delete_line "!ui_dom_file!" "!l_num!"
if /i "!l_type!"=="I" call :delete_line "!ui_ip_file!" "!l_num!"

goto ui_loop

:list_content
set "l_file=%~1"
set "l_prefix=%~2"
findstr /n /r "." "!l_file!" > "%temp%\z_list.tmp"
set "empty_check=1"
for /f "usebackq tokens=1,* delims=:" %%A in ("%temp%\z_list.tmp") do (
    echo      [!l_prefix!%%A] %%B
    set "empty_check=0"
)
if "!empty_check!"=="1" echo      (Empty)
del "%temp%\z_list.tmp" >nul 2>&1
goto :eof

:delete_line
set "l_file=%~1"
set "l_line=%~2"
if "!l_line!"=="" goto :eof
set "temp_file=!l_file!.tmp"
type nul > "!temp_file!"
set "l_deleted=0"
findstr /n /r "." "!l_file!" > "%temp%\z_del.tmp"
for /f "usebackq tokens=1,* delims=:" %%A in ("%temp%\z_del.tmp") do (
    if "%%A"=="!l_line!" (
        call :PrintYellow "   [-] Deleted: %%B"
        set "l_deleted=1"
    ) else (
        >>"!temp_file!" echo %%B
    )
)
del "%temp%\z_del.tmp" >nul 2>&1
if "!l_deleted!"=="1" (move /y "!temp_file!" "!l_file!" >nul) else (del "!temp_file!" >nul 2>&1)
timeout /t 1 >nul
goto :eof

:: INSPECTOR ===========================
:inspector
echo.
set "raw_search="
set /p "raw_search=   > Paste link, domain or IP to search: "
if "!raw_search!"=="" goto :eof

:: Smart очистка ввода (аналогично Add)
set "search_val=!raw_search: =!"
set "search_val=!search_val:http://=!"
set "search_val=!search_val:https://=!"
set "search_val=!search_val:www.=!"
for /f "tokens=1 delims=/" %%a in ("!search_val!") do set "search_val=%%a"
echo !raw_search! | findstr /R "[0-9]/[0-9]" >nul
if !errorlevel!==0 for /f "tokens=1 delims= " %%a in ("!raw_search!") do set "search_val=%%a"

echo.
call :PrintYellow "   [*] Inspecting lists for '!search_val!'..."
set "found=0"

for %%F in ("!LISTS_PATH!*.txt") do (
    findstr /x /i /c:"!search_val!" "%%F" >nul 2>&1
    if !errorlevel!==0 (
        call :PrintGreen "   [!] Found in: %%~nxF"
        set "found=1"
    )
)
if "!found!"=="0" call :PrintRed "   [X] Resource not found in any list."
echo.
echo   Press any key to return...
pause >nul
goto :eof

:: RESTART SERVICE =====================
:restart_zapret
echo.
sc query "zapret" | findstr /i "RUNNING" >nul 2>&1
if !errorlevel!==0 (
    call :PrintYellow "   [*] Restarting zapret service..."
    net stop zapret >nul 2>&1
    net start zapret >nul 2>&1
    call :PrintGreen "   [+] Service restarted successfully!"
) else (
    call :PrintRed "   [X] 'zapret' service is not running."
    call :PrintYellow "       If you use general.bat, please restart it manually."
)
echo.
echo   Press any key to return...
pause >nul
goto :eof

:: Utility functions ===================
:PrintGreen
powershell -NoProfile -Command "Write-Host \"%~1\" -ForegroundColor Green"
goto :eof
:PrintRed
powershell -NoProfile -Command "Write-Host \"%~1\" -ForegroundColor Red"
goto :eof
:PrintYellow
powershell -NoProfile -Command "Write-Host \"%~1\" -ForegroundColor Yellow"
goto :eof