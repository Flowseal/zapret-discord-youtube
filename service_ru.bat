@echo off
chcp 65001 >nul
set "LOCAL_VERSION=1.9.5"

:: Внешние команды
if "%~1"=="status_zapret" (
    call :test_service zapret soft
    call :tcp_enable
    exit /b
)

if "%~1"=="check_updates" (
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

if "%1"=="admin" (
    chcp 65001 >nul
    call :check_command chcp
    call :check_command find
    call :check_command findstr
    call :check_command netsh

    echo Запущено с правами администратора
) else (
    call :check_extracted
    call :check_command powershell

    echo Запрашиваю права администратора...
    powershell -NoProfile -Command "Start-Process 'cmd.exe' -ArgumentList '/c \"\"%~f0\" admin\"' -Verb RunAs"
    exit
)

:: МЕНЮ ================================
setlocal EnableDelayedExpansion
:menu
cls
call :ipset_switch_status
call :game_switch_status
call :check_updates_switch_status

set "menu_choice=null"

echo.
echo   МЕНЕДЖЕР СЛУЖБЫ ZAPRET v!LOCAL_VERSION!
echo   ----------------------------------------
echo.
echo   :: СЛУЖБА
echo      1. Установить службу
echo      2. Удалить службы
echo      3. Проверить состояние
echo.
echo   :: НАСТРОЙКИ
echo      4. Фильтр игр         [!GameFilterStatus!]
echo      5. IPSet фильтр       [!IPsetStatus!]
echo      6. Авто-проверка обновлений   [!CheckUpdatesStatus!]
echo.
echo   :: ОБНОВЛЕНИЯ
echo      7. Обновить список IPSet
echo      8. Обновить файл Hosts
echo      9. Проверить обновления
echo.
echo   :: ИНСТРУМЕНТЫ
echo      10. Запустить диагностику
echo      11. Запустить тесты
echo.
echo   ----------------------------------------
echo      0. Выход
echo.

set /p menu_choice=   Выберите опцию (0-11): 

if "%menu_choice%"=="1" goto service_install
if "%menu_choice%"=="2" goto service_remove
if "%menu_choice%"=="3" goto service_status
if "%menu_choice%"=="4" goto game_switch
if "%menu_choice%"=="5" goto ipset_switch
if "%menu_choice%"=="6" goto check_updates_switch
if "%menu_choice%"=="7" goto ipset_update
if "%menu_choice%"=="8" goto hosts_update
if "%menu_choice%"=="9" goto service_check_updates
if "%menu_choice%"=="10" goto service_diagnostics
if "%menu_choice%"=="11" goto run_tests
if "%menu_choice%"=="0" exit /b
goto menu


:: TCP ВКЛЮЧЕНИЕ ==========================
:tcp_enable
netsh interface tcp show global | findstr /i "timestamps" | findstr /i "enabled" > nul || netsh interface tcp set global timestamps=enabled > nul 2>&1
exit /b


:: СОСТОЯНИЕ ==============================
:service_status
cls
chcp 65001 >nul

sc query "zapret" >nul 2>&1
if !errorlevel!==0 (
    for /f "tokens=2*" %%A in ('reg query "HKLM\System\CurrentControlSet\Services\zapret" /v zapret-discord-youtube 2^>nul') do echo Стратегия службы установлена из "%%B"
)

call :test_service zapret
call :test_service WinDivert

set "BIN_PATH=%~dp0bin\"
if not exist "%BIN_PATH%\*.sys" (
    call :PrintRed "Файл WinDivert64.sys НЕ найден."
)
echo:

tasklist /FI "IMAGENAME eq winws.exe" | find /I "winws.exe" > nul
if !errorlevel!==0 (
    call :PrintGreen "Обход (winws.exe) ЗАПУЩЕН."
) else (
    call :PrintRed "Обход (winws.exe) НЕ запущен."
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
        echo "%ServiceName%" УЖЕ ЗАПУЩЕН как служба, используйте "service.bat" и выберите "Удалить службы" сначала, если хотите запустить отдельный bat-файл.
        pause
        exit /b
    ) else (
        echo Служба "%ServiceName%" ЗАПУЩЕНА.
    )
) else if "%ServiceStatus%"=="STOP_PENDING" (
    call :PrintYellow "!ServiceName! в состоянии ОСТАНОВКИ, это может быть вызвано конфликтом с другим обходом. Запустите диагностику, чтобы попытаться устранить конфликты"
) else if not "%~2"=="soft" (
    echo Служба "%ServiceName%" НЕ запущена.
)

exit /b


:: УДАЛЕНИЕ ==============================
:service_remove
cls
chcp 65001 > nul

set SRVCNAME=zapret
sc query "!SRVCNAME!" >nul 2>&1
if !errorlevel!==0 (
    net stop %SRVCNAME%
    sc delete %SRVCNAME%
) else (
    echo Служба "%SRVCNAME%" не установлена.
)

tasklist /FI "IMAGENAME eq winws.exe" | find /I "winws.exe" > nul
if !errorlevel!==0 (
    taskkill /IM winws.exe /F > nul
)

sc query "WinDivert" >nul 2>&1
if !errorlevel!==0 (
    net stop "WinDivert"

    sc query "WinDivert" >nul 2>&1
    if !errorlevel!==0 (
        sc delete "WinDivert"
    )
)
net stop "WinDivert14" >nul 2>&1
sc delete "WinDivert14" >nul 2>&1

pause
goto menu


:: УСТАНОВКА =============================
:service_install
cls
chcp 65001 > nul

:: Основное
cd /d "%~dp0"
set "BIN_PATH=%~dp0bin\"
set "LISTS_PATH=%~dp0lists\"

:: Поиск .bat файлов в текущей папке, кроме файлов, начинающихся с "service"
echo Выберите один из вариантов:
set "count=0"
for /f "delims=" %%F in ('powershell -NoProfile -Command "Get-ChildItem -LiteralPath '.' -Filter '*.bat' | Where-Object { $_.Name -notlike 'service*' } | Sort-Object { [Regex]::Replace($_.Name, '(\d+)', { $args[0].Value.PadLeft(8, '0') }) } | ForEach-Object { $_.Name }"') do (
    set /a count+=1
    echo !count!. %%F
    set "file!count!=%%F"
)

:: Выбор файла
set "choice="
set /p "choice=Введите индекс файла (номер): "
if "!choice!"=="" (
    echo Выбор пуст, выход...
    pause
    goto menu
)

set "selectedFile=!file%choice%!"
if not defined selectedFile (
    echo Неверный выбор, выход...
    pause
    goto menu
)

:: Аргументы, за которыми должно следовать значение
set "args_with_value=sni host altorder"

:: Разбор аргументов (mergeargs: 2=начало параметра|3=аргумент со значением|1=параметры аргументов|0=по умолчанию)
set "args="
set "capture=0"
set "mergeargs=0"
set QUOTE="

for /f "tokens=*" %%a in ('type "!selectedFile!"') do (
    set "line=%%a"
    call set "line=%%line:^!=EXCL_MARK%%"

    echo !line! | findstr /i "%BIN%winws.exe" >nul
    if not errorlevel 1 (
        set "capture=1"
    )

    if !capture!==1 (
        if not defined args (
            set "line=!line:*%BIN%winws.exe"=!"
        )

        set "temp_args="
        for %%i in (!line!) do (
            set "arg=%%i"

            if not "!arg!"=="^" (
                if "!arg:~0,2!" EQU "--" if not !mergeargs!==0 (
                    set "mergeargs=0"
                )

                if "!arg:~0,1!" EQU "!QUOTE!" (
                    set "arg=!arg:~1,-1!"

                    echo !arg! | findstr ":" >nul
                    if !errorlevel!==0 (
                        set "arg=\!QUOTE!!arg!\!QUOTE!"
                    ) else if "!arg:~0,1!"=="@" (
                        set "arg=\!QUOTE!@%~dp0!arg:~1!\!QUOTE!"
                    ) else if "!arg:~0,5!"=="%%BIN%%" (
                        set "arg=\!QUOTE!!BIN_PATH!!arg:~5!\!QUOTE!"
                    ) else if "!arg:~0,7!"=="%%LISTS%%" (
                        set "arg=\!QUOTE!!LISTS_PATH!!arg:~7!\!QUOTE!"
                    ) else (
                        set "arg=\!QUOTE!%~dp0!arg!\!QUOTE!"
                    )
                ) else if "!arg:~0,12!" EQU "%%GameFilter%%" (
                    set "arg=%GameFilter%"
                )

                if !mergeargs!==1 (
                    set "temp_args=!temp_args!,!arg!"
                ) else if !mergeargs!==3 (
                    set "temp_args=!temp_args!=!arg!"
                    set "mergeargs=1"
                ) else (
                    set "temp_args=!temp_args! !arg!"
                )

                if "!arg:~0,2!" EQU "--" (
                    set "mergeargs=2"
                ) else if !mergeargs! GEQ 1 (
                    if !mergeargs!==2 set "mergeargs=1"

                    for %%x in (!args_with_value!) do (
                        if /i "%%x"=="!arg!" (
                            set "mergeargs=3"
                        )
                    )
                )
            )
        )

        if not "!temp_args!"=="" (
            set "args=!args! !temp_args!"
        )
    )
)

:: Создание службы с разобранными аргументами
call :tcp_enable

set ARGS=%args%
call set "ARGS=%%ARGS:EXCL_MARK=^!%%"
echo Итоговые аргументы: !ARGS!
set SRVCNAME=zapret

net stop %SRVCNAME% >nul 2>&1
sc delete %SRVCNAME% >nul 2>&1
sc create %SRVCNAME% binPath= "\"%BIN_PATH%winws.exe\" !ARGS!" DisplayName= "zapret" start= auto
sc description %SRVCNAME% "Программа обхода DPI Zapret"
sc start %SRVCNAME%
for %%F in ("!file%choice%!") do (
    set "filename=%%~nF"
)
reg add "HKLM\System\CurrentControlSet\Services\zapret" /v zapret-discord-youtube /t REG_SZ /d "!filename!" /f

pause
goto menu


:: ПРОВЕРКА ОБНОВЛЕНИЙ =======================
:service_check_updates
chcp 65001 > nul
cls

:: Установка текущей версии и URL-адресов
set "GITHUB_VERSION_URL=https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/main/.service/version.txt"
set "GITHUB_RELEASE_URL=https://github.com/Flowseal/zapret-discord-youtube/releases/tag/"
set "GITHUB_DOWNLOAD_URL=https://github.com/Flowseal/zapret-discord-youtube/releases/latest"

:: Получение последней версии из GitHub
for /f "delims=" %%A in ('powershell -NoProfile -Command "(Invoke-WebRequest -Uri \"%GITHUB_VERSION_URL%\" -Headers @{\"Cache-Control\"=\"no-cache\"} -UseBasicParsing -TimeoutSec 5).Content.Trim()" 2^>nul') do set "GITHUB_VERSION=%%A"

:: Обработка ошибок
if not defined GITHUB_VERSION (
    echo Предупреждение: не удалось получить последнюю версию. Это предупреждение не влияет на работу zapret
    timeout /T 9
    if "%1"=="soft" exit 
    goto menu
)

:: Сравнение версий
if "%LOCAL_VERSION%"=="%GITHUB_VERSION%" (
    echo Установлена последняя версия: %LOCAL_VERSION%
    
    if "%1"=="soft" exit 
    pause
    goto menu
) 

echo Доступна новая версия: %GITHUB_VERSION%
echo Страница выпуска: %GITHUB_RELEASE_URL%%GITHUB_VERSION%

echo Открываю страницу загрузки...
start "" "%GITHUB_DOWNLOAD_URL%"


if "%1"=="soft" exit 
pause
goto menu



:: ДИАГНОСТИКА =========================
:service_diagnostics
chcp 65001 > nul
cls

:: Базовый механизм фильтрации
sc query BFE | findstr /I "RUNNING" > nul
if !errorlevel!==0 (
    call :PrintGreen "Проверка базового механизма фильтрации пройдена"
) else (
    call :PrintRed "[X] Базовый механизм фильтрации не запущен. Эта служба необходима для работы zapret"
)
echo:

:: Проверка прокси
set "proxyEnabled=0"
set "proxyServer="

for /f "tokens=2*" %%A in ('reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyEnable 2^>nul ^| findstr /i "ProxyEnable"') do (
    if "%%B"=="0x1" set "proxyEnabled=1"
)

if !proxyEnabled!==1 (
    for /f "tokens=2*" %%A in ('reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyServer 2^>nul ^| findstr /i "ProxyServer"') do (
        set "proxyServer=%%B"
    )
    
    call :PrintYellow "[?] Системный прокси включен: !proxyServer!"
    call :PrintYellow "Убедитесь, что он действителен, или отключите, если не используете прокси"
) else (
    call :PrintGreen "Проверка прокси пройдена"
)
echo:

:: Проверка TCP временных меток
netsh interface tcp show global | findstr /i "timestamps" | findstr /i "enabled" > nul
if !errorlevel!==0 (
    call :PrintGreen "Проверка TCP временных меток пройдена"
) else (
    call :PrintYellow "[?] TCP временные метки отключены. Включаю метки..."
    netsh interface tcp set global timestamps=enabled > nul 2>&1
    if !errorlevel!==0 (
        call :PrintGreen "TCP временные метки успешно включены"
    ) else (
        call :PrintRed "[X] Не удалось включить TCP временные метки"
    )
)
echo:

:: AdguardSvc.exe
tasklist /FI "IMAGENAME eq AdguardSvc.exe" | find /I "AdguardSvc.exe" > nul
if !errorlevel!==0 (
    call :PrintRed "[X] Найден процесс Adguard. Adguard может вызвать проблемы с Discord"
    call :PrintRed "https://github.com/Flowseal/zapret-discord-youtube/issues/417"
) else (
    call :PrintGreen "Проверка Adguard пройдена"
)
echo:

:: Killer
sc query | findstr /I "Killer" > nul
if !errorlevel!==0 (
    call :PrintRed "[X] Найдены службы Killer. Killer конфликтует с zapret"
    call :PrintRed "https://github.com/Flowseal/zapret-discord-youtube/issues/2512#issuecomment-2821119513"
) else (
    call :PrintGreen "Проверка Killer пройдена"
)
echo:

:: Служба сетевых подключений Intel
sc query | findstr /I "Intel" | findstr /I "Connectivity" | findstr /I "Network" > nul
if !errorlevel!==0 (
    call :PrintRed "[X] Найдена служба сетевых подключений Intel. Она конфликтует с zapret"
    call :PrintRed "https://github.com/ValdikSS/GoodbyeDPI/issues/541#issuecomment-2661670982"
) else (
    call :PrintGreen "Проверка подключений Intel пройдена"
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
    call :PrintRed "[X] Найдены службы Check Point. Check Point конфликтует с zapret"
    call :PrintRed "Попробуйте удалить Check Point"
) else (
    call :PrintGreen "Проверка Check Point пройдена"
)
echo:

:: SmartByte
sc query | findstr /I "SmartByte" > nul
if !errorlevel!==0 (
    call :PrintRed "[X] Найдены службы SmartByte. SmartByte конфликтует с zapret"
    call :PrintRed "Попробуйте удалить или отключить SmartByte через services.msc"
) else (
    call :PrintGreen "Проверка SmartByte пройдена"
)
echo:

:: Файл WinDivert64.sys
set "BIN_PATH=%~dp0bin\"
if not exist "%BIN_PATH%\*.sys" (
    call :PrintRed "Файл WinDivert64.sys НЕ найден."
    echo:
)

:: VPN
set "VPN_SERVICES="
sc query | findstr /I "VPN" > nul
if !errorlevel!==0 (
    for /f "tokens=2 delims=:" %%A in ('sc query ^| findstr /I "VPN"') do (
        if not defined VPN_SERVICES (
            set "VPN_SERVICES=!VPN_SERVICES!%%A"
        ) else (
            set "VPN_SERVICES=!VPN_SERVICES!,%%A"
        )
    )
    call :PrintYellow "[?] Найдены VPN-службы:!VPN_SERVICES!. Некоторые VPN могут конфликтовать с zapret"
    call :PrintYellow "Убедитесь, что все VPN отключены"
) else (
    call :PrintGreen "Проверка VPN пройдена"
)
echo:

:: DNS
set "dohfound=0"
for /f "delims=" %%a in ('powershell -NoProfile -Command "Get-ChildItem -Recurse -Path 'HKLM:System\CurrentControlSet\Services\Dnscache\InterfaceSpecificParameters\' | Get-ItemProperty | Where-Object { $_.DohFlags -gt 0 } | Measure-Object | Select-Object -ExpandProperty Count"') do (
    if %%a gtr 0 (
        set "dohfound=1"
    )
)
if !dohfound!==0 (
    call :PrintYellow "[?] Убедитесь, что вы настроили безопасный DNS в браузере с каким-либо нестандартным поставщиком DNS-услуг,"
    call :PrintYellow "Если вы используете Windows 11, вы можете настроить зашифрованный DNS в Настройках, чтобы скрыть это предупреждение"
) else (
    call :PrintGreen "Проверка безопасного DNS пройдена"
)
echo:

:: Конфликт WinDivert
tasklist /FI "IMAGENAME eq winws.exe" | find /I "winws.exe" > nul
set "winws_running=!errorlevel!"

sc query "WinDivert" | findstr /I "RUNNING STOP_PENDING" > nul
set "windivert_running=!errorlevel!"

if !winws_running! neq 0 if !windivert_running!==0 (
    call :PrintYellow "[?] winws.exe не запущен, но служба WinDivert активна. Попытка удалить WinDivert..."
    
    net stop "WinDivert" >nul 2>&1
    sc delete "WinDivert" >nul 2>&1
    sc query "WinDivert" >nul 2>&1
    if !errorlevel!==0 (
        call :PrintRed "[X] Не удалось удалить WinDivert. Проверка на конфликтующие службы..."
        
        set "conflicting_services=GoodbyeDPI"
        set "found_conflict=0"
        
        for %%s in (!conflicting_services!) do (
            sc query "%%s" >nul 2>&1
            if !errorlevel!==0 (
                call :PrintYellow "[?] Найдена конфликтующая служба: %%s. Остановка и удаление..."
                net stop "%%s" >nul 2>&1
                sc delete "%%s" >nul 2>&1
                if !errorlevel!==0 (
                    call :PrintGreen "Служба успешно удалена: %%s"
                ) else (
                    call :PrintRed "[X] Не удалось удалить службу: %%s"
                )
                set "found_conflict=1"
            )
        )
        
        if !found_conflict!==0 (
            call :PrintRed "[X] Конфликтующие службы не найдены. Проверьте вручную, не использует ли другой обход WinDivert."
        ) else (
            call :PrintYellow "[?] Повторная попытка удалить WinDivert..."

            net stop "WinDivert" >nul 2>&1
            sc delete "WinDivert" >nul 2>&1
            sc query "WinDivert" >nul 2>&1
            if !errorlevel! neq 0 (
                call :PrintGreen "WinDivert успешно удален после удаления конфликтующих служб"
            ) else (
                call :PrintRed "[X] WinDivert все еще не может быть удален. Проверьте вручную, не использует ли другой обход WinDivert."
            )
        )
    ) else (
        call :PrintGreen "WinDivert успешно удален"
    )
    
    echo:
)

:: Конфликтующие обходы
set "conflicting_services=GoodbyeDPI discordfix_zapret winws1 winws2"
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
    call :PrintRed "[X] Найдены конфликтующие службы обхода: !found_conflicts!"
    
    set "CHOICE="
    set /p "CHOICE=Хотите удалить эти конфликтующие службы? (Y/N) (по умолчанию: N) "
    if "!CHOICE!"=="" set "CHOICE=N"
    if "!CHOICE!"=="y" set "CHOICE=Y"
    
    if /i "!CHOICE!"=="Y" (
        for %%s in (!found_conflicts!) do (
            call :PrintYellow "Остановка и удаление службы: %%s"
            net stop "%%s" >nul 2>&1
            sc delete "%%s" >nul 2>&1
            if !errorlevel!==0 (
                call :PrintGreen "Служба успешно удалена: %%s"
            ) else (
                call :PrintRed "[X] Не удалось удалить службу: %%s"
            )
        )

        net stop "WinDivert" >nul 2>&1
        sc delete "WinDivert" >nul 2>&1
        net stop "WinDivert14" >nul 2>&1
        sc delete "WinDivert14" >nul 2>&1
    )
    
    echo:
)

:: Очистка кэша Discord
set "CHOICE="
set /p "CHOICE=Хотите очистить кэш Discord? (Y/N) (по умолчанию: Y)  "
if "!CHOICE!"=="" set "CHOICE=Y"
if "!CHOICE!"=="y" set "CHOICE=Y"

if /i "!CHOICE!"=="Y" (
    tasklist /FI "IMAGENAME eq Discord.exe" | findstr /I "Discord.exe" > nul
    if !errorlevel!==0 (
        echo Discord запущен, закрываю...
        taskkill /IM Discord.exe /F > nul
        if !errorlevel! == 0 (
            call :PrintGreen "Discord успешно закрыт"
        ) else (
            call :PrintRed "Не удалось закрыть Discord"
        )
    )

    set "discordCacheDir=%appdata%\discord"

    for %%d in ("Cache" "Code Cache" "GPUCache") do (
        set "dirPath=!discordCacheDir!\%%~d"
        if exist "!dirPath!" (
            rd /s /q "!dirPath!"
            if !errorlevel!==0 (
                call :PrintGreen "Успешно удалено !dirPath!"
            ) else (
                call :PrintRed "Не удалось удалить !dirPath!"
            )
        ) else (
            call :PrintRed "!dirPath! не существует"
        )
    )
)
echo:

pause
goto menu


:: ПЕРЕКЛЮЧАТЕЛЬ ИГР ========================
:game_switch_status
chcp 65001 > nul

set "gameFlagFile=%~dp0utils\game_filter.enabled"

if exist "%gameFlagFile%" (
    set "GameFilterStatus=включен"
    set "GameFilter=1024-65535"
) else (
    set "GameFilterStatus=выключен"
    set "GameFilter=12"
)
exit /b


:game_switch
chcp 65001 > nul
cls

if not exist "%gameFlagFile%" (
    echo Включаю фильтр игр...
    echo ENABLED > "%gameFlagFile%"
    call :PrintYellow "Перезапустите zapret для применения изменений"
) else (
    echo Выключаю фильтр игр...
    del /f /q "%gameFlagFile%"
    call :PrintYellow "Перезапустите zapret для применения изменений"
)

pause
goto menu


:: ПЕРЕКЛЮЧАТЕЛЬ ПРОВЕРКИ ОБНОВЛЕНИЙ =================
:check_updates_switch_status
chcp 65001 > nul

set "checkUpdatesFlag=%~dp0utils\check_updates.enabled"

if exist "%checkUpdatesFlag%" (
    set "CheckUpdatesStatus=включена"
) else (
    set "CheckUpdatesStatus=выключена"
)
exit /b


:check_updates_switch
chcp 65001 > nul
cls

if not exist "%checkUpdatesFlag%" (
    echo Включаю проверку обновлений...
    echo ENABLED > "%checkUpdatesFlag%"
) else (
    echo Выключаю проверку обновлений...
    del /f /q "%checkUpdatesFlag%"
)

pause
goto menu


:: ПЕРЕКЛЮЧАТЕЛЬ IPSET =======================
:ipset_switch_status
chcp 65001 > nul

set "listFile=%~dp0lists\ipset-all.txt"
for /f %%i in ('type "%listFile%" 2^>nul ^| find /c /v ""') do set "lineCount=%%i"

if !lineCount!==0 (
    set "IPsetStatus=любой"
) else (
    findstr /R "^203\.0\.113\.113/32$" "%listFile%" >nul
    if !errorlevel!==0 (
        set "IPsetStatus=никакой"
    ) else (
        set "IPsetStatus=загружен"
    )
)
exit /b


:ipset_switch
chcp 65001 > nul
cls

set "listFile=%~dp0lists\ipset-all.txt"
set "backupFile=%listFile%.backup"

if "%IPsetStatus%"=="загружен" (
    echo Переключаю в режим "никакой"...
    
    if not exist "%backupFile%" (
        ren "%listFile%" "ipset-all.txt.backup"
    ) else (
        del /f /q "%backupFile%"
        ren "%listFile%" "ipset-all.txt.backup"
    )
    
    >"%listFile%" (
        echo 203.0.113.113/32
    )
    
) else if "%IPsetStatus%"=="никакой" (
    echo Переключаю в режим "любой"...
    
    >"%listFile%" (
        rem Создание пустого файла
    )
    
) else if "%IPsetStatus%"=="любой" (
    echo Переключаю в режим "загружен"...
    
    if exist "%backupFile%" (
        del /f /q "%listFile%"
        ren "%backupFile%" "ipset-all.txt"
    ) else (
        echo Ошибка: нет резервной копии для восстановления. Сначала обновите список из меню службы
        pause
        goto menu
    )
    
)

pause
goto menu


:: ОБНОВЛЕНИЕ IPSET =======================
:ipset_update
chcp 65001 > nul
cls

set "listFile=%~dp0lists\ipset-all.txt"
set "url=https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/refs/heads/main/.service/ipset-service.txt"

echo Обновляю ipset-all...

if exist "%SystemRoot%\System32\curl.exe" (
    curl -L -o "%listFile%" "%url%"
) else (
    powershell -NoProfile -Command ^
        "$url = '%url%';" ^
        "$out = '%listFile%';" ^
        "$dir = Split-Path -Parent $out;" ^
        "if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null };" ^
        "$res = Invoke-WebRequest -Uri $url -TimeoutSec 10 -UseBasicParsing;" ^
        "if ($res.StatusCode -eq 200) { $res.Content | Out-File -FilePath $out -Encoding UTF8 } else { exit 1 }"
)

echo Завершено

pause
goto menu


:: ОБНОВЛЕНИЕ HOSTS =======================
:hosts_update
chcp 65001 > nul
cls

set "hostsFile=%SystemRoot%\System32\drivers\etc\hosts"
set "hostsUrl=https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/refs/heads/main/.service/hosts"
set "tempFile=%TEMP%\zapret_hosts.txt"
set "needsUpdate=0"

echo Проверяю файл hosts...

if exist "%SystemRoot%\System32\curl.exe" (
    curl -L -s -o "%tempFile%" "%hostsUrl%"
) else (
    powershell -NoProfile -Command ^
        "$url = '%hostsUrl%';" ^
        "$out = '%tempFile%';" ^
        "$res = Invoke-WebRequest -Uri $url -TimeoutSec 10 -UseBasicParsing;" ^
        "if ($res.StatusCode -eq 200) { $res.Content | Out-File -FilePath $out -Encoding UTF8 } else { exit 1 }"
)

if not exist "%tempFile%" (
    call :PrintRed "Не удалось загрузить файл hosts из репозитория"
    call :PrintYellow "Скопируйте файл hosts вручную из %hostsUrl%"
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

findstr /C:"!firstLine!" "%hostsFile%" >nul 2>&1
if !errorlevel! neq 0 (
    echo Первая строка из репозитория не найдена в файле hosts
    set "needsUpdate=1"
)

findstr /C:"!lastLine!" "%hostsFile%" >nul 2>&1
if !errorlevel! neq 0 (
    echo Последняя строка из репозитория не найдена в файле hosts
    set "needsUpdate=1"
)

if "%needsUpdate%"=="1" (
    echo:
    call :PrintYellow "Файл hosts нуждается в обновлении"
    call :PrintYellow "Пожалуйста, вручную скопируйте содержимое из загруженного файла в ваш файл hosts"
    
    start notepad "%tempFile%"
    explorer /select,"%hostsFile%"
) else (
    call :PrintGreen "Файл hosts актуален"
    if exist "%tempFile%" del /f /q "%tempFile%"
)

echo:
pause
goto menu


:: ЗАПУСК ТЕСТОВ =============================
:run_tests
chcp 65001 >nul
cls

:: Требуется PowerShell 3.0+
powershell -NoProfile -Command "if ($PSVersionTable -and $PSVersionTable.PSVersion -and $PSVersionTable.PSVersion.Major -ge 3) { exit 0 } else { exit 1 }" >nul 2>&1
if %errorLevel% neq 0 (
    echo Требуется PowerShell 3.0 или новее.
    echo Пожалуйста, обновите PowerShell и перезапустите этот скрипт.
    echo.
    pause
    goto menu
)

echo Запускаю тесты конфигурации в окне PowerShell...
echo.
start "" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0utils\test zapret.ps1"
pause
goto menu


:: Вспомогательные функции

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
    echo [ОШИБКА] %1 не найден в PATH
    echo Исправьте переменную PATH с инструкциями здесь https://github.com/Flowseal/zapret-discord-youtube/issues/7490
    pause
    exit /b 1
)
exit /b 0

:check_extracted
set "extracted=1"

if not exist "%~dp0bin\" set "extracted=0"

if "%extracted%"=="0" (
    echo Zapret должен быть сначала извлечен из архива или папка bin не найдена по какой-то причине
    pause
    exit
)
exit /b 0