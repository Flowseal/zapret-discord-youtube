@echo off

:: ============================================
:: AUTO-ELEVATE TO ADMIN
:: ============================================
net session >nul 2>&1
if errorlevel 1 (
    echo Requesting admin rights...
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

:: ============================================
:: MAIN SCRIPT (runs as admin)
:: ============================================
chcp 866 >nul
setlocal EnableDelayedExpansion
cd /d "%~dp0"

set "BIN=%~dp0bin\"
set "LISTS=%~dp0lists\"
set "RESFILE=%~dp0working_configs.txt"

:mainmenu
cls
echo.
echo  ===========================================================================
echo                    ZAPRET BRUTEFORCER v5.2 [ADMIN]
echo              (with video stream and Discord checks)
echo  ===========================================================================
echo.
echo  Folder: %CD%
echo.
echo  ---------------------------------------------------------------------------
echo    [1] Quick Start - YouTube (video check)
echo    [2] Quick Start - Discord (CDN + gateway)
echo    [3] Quick Start - Both YouTube + Discord
echo    [4] Manual Setup
echo    [5] Test .bat strategies only
echo    [6] Quick test single params
echo    [7] Diagnostics
echo    [0] Exit
echo  ---------------------------------------------------------------------------
echo.
set "MENUCHOICE="
set /p "MENUCHOICE=Choice: "

if "%MENUCHOICE%"=="1" goto opt_quickyt
if "%MENUCHOICE%"=="2" goto opt_quickdc
if "%MENUCHOICE%"=="3" goto opt_quickboth
if "%MENUCHOICE%"=="4" goto opt_manual
if "%MENUCHOICE%"=="5" goto opt_batonly
if "%MENUCHOICE%"=="6" goto opt_quicktest
if "%MENUCHOICE%"=="7" goto opt_diag
if "%MENUCHOICE%"=="0" goto opt_exit
goto mainmenu

:opt_exit
endlocal
exit /b 0

:opt_diag
cls
echo.
echo  ===========================================================================
echo   DIAGNOSTICS
echo  ===========================================================================
echo.

echo [1/8] Admin rights...
net session >nul 2>&1
if errorlevel 1 (
    echo       [FAIL] Not admin!
) else (
    echo       [OK] Running as admin
)
echo.

echo [2/8] Checking curl...
where curl >nul 2>&1
if errorlevel 1 (
    echo       [FAIL] curl not found in PATH!
) else (
    echo       [OK] curl found
)
echo.

echo [3/8] Checking winws.exe...
if exist "%BIN%winws.exe" (
    echo       [OK] bin\winws.exe found
) else (
    echo       [FAIL] bin\winws.exe not found!
)
echo.

echo [4/8] Checking lists...
if exist "%LISTS%list-general.txt" (
    echo       [OK] lists\list-general.txt found
) else (
    echo       [WARN] lists\list-general.txt not found
)
echo.

echo [5/8] Testing YouTube page...
curl -s -o nul -w "%%{http_code}" --connect-timeout 5 --max-time 8 "https://www.youtube.com" 2>nul | findstr /r "^[23]" >nul
if errorlevel 1 (
    echo       [BLOCKED] youtube.com
) else (
    echo       [OK] youtube.com accessible
)
echo.

echo [6/8] Testing YouTube video (i.ytimg.com)...
curl -s -o nul -w "%%{http_code}" --connect-timeout 5 --max-time 8 "https://i.ytimg.com/vi/dQw4w9WgXcQ/default.jpg" 2>nul | findstr /r "^[23]" >nul
if errorlevel 1 (
    echo       [BLOCKED] i.ytimg.com
) else (
    echo       [OK] i.ytimg.com accessible
)
echo.

echo [7/8] Testing Discord CDN...
curl -s -o nul -w "%%{http_code}" --connect-timeout 5 --max-time 8 "https://cdn.discordapp.com/embed/avatars/0.png" 2>nul | findstr /r "^[23]" >nul
if errorlevel 1 (
    echo       [BLOCKED] Discord CDN
) else (
    echo       [OK] Discord CDN accessible
)
echo.

echo [8/8] Checking winws.exe process...
tasklist /fi "imagename eq winws.exe" 2>nul | find /i "winws.exe" >nul
if errorlevel 1 (
    echo       [INFO] winws.exe not running
) else (
    echo       [OK] winws.exe is running
    echo       Trying to stop...
    taskkill /f /im winws.exe
    if errorlevel 1 (
        echo       [FAIL] Could not stop
    ) else (
        echo       [OK] Stopped
    )
)
echo.

echo  ===========================================================================
echo.
pause
goto mainmenu

:opt_quickyt
cls
echo.
echo  ===========================================================================
echo   QUICK START - YOUTUBE (VIDEO CHECK)
echo  ===========================================================================
echo.
echo  Will check:
echo    1. youtube.com page
echo    2. i.ytimg.com (video thumbnails/CDN)
echo.
echo  Mode: BAT first, then generate / Level: 2 / Stop on first: Yes
echo.

set "CHECKMODE=youtube"
set "RUNMODE=3"
set "BFLEVEL=2"
set "STOPFIRST=1"
set "INITTIMEOUT=7"
set "CURLTIMEOUT=10"
set "MAXATTEMPTS=2"

set "STARTCONFIRM="
set /p "STARTCONFIRM=Start? (y/n): "
if /i not "%STARTCONFIRM%"=="y" goto mainmenu
goto startbrute

:opt_quickdc
cls
echo.
echo  ===========================================================================
echo   QUICK START - DISCORD
echo  ===========================================================================
echo.
echo  Will check:
echo    1. discord.com
echo    2. cdn.discordapp.com
echo    3. gateway.discord.gg
echo.
echo  Mode: BAT first, then generate / Level: 2 / Stop on first: Yes
echo.

set "CHECKMODE=discord"
set "RUNMODE=3"
set "BFLEVEL=2"
set "STOPFIRST=1"
set "INITTIMEOUT=7"
set "CURLTIMEOUT=10"
set "MAXATTEMPTS=2"

set "STARTCONFIRM="
set /p "STARTCONFIRM=Start? (y/n): "
if /i not "%STARTCONFIRM%"=="y" goto mainmenu
goto startbrute

:opt_quickboth
cls
echo.
echo  ===========================================================================
echo   QUICK START - YOUTUBE + DISCORD
echo  ===========================================================================
echo.
echo  Will check BOTH services
echo  Strategy must work for both to pass
echo.
echo  Mode: BAT first, then generate / Level: 2 / Stop on first: Yes
echo.

set "CHECKMODE=both"
set "RUNMODE=3"
set "BFLEVEL=2"
set "STOPFIRST=1"
set "INITTIMEOUT=8"
set "CURLTIMEOUT=10"
set "MAXATTEMPTS=2"

set "STARTCONFIRM="
set /p "STARTCONFIRM=Start? (y/n): "
if /i not "%STARTCONFIRM%"=="y" goto mainmenu
goto startbrute

:opt_manual
cls
echo.
echo  ===========================================================================
echo   MANUAL SETUP
echo  ===========================================================================
echo.

echo  What to check:
echo    [1] YouTube (page + video)
echo    [2] Discord (CDN + gateway)
echo    [3] Both YouTube + Discord
echo.
set "TARGETCHOICE="
set /p "TARGETCHOICE=Choice (1-3) [1]: "
if "%TARGETCHOICE%"=="" set "TARGETCHOICE=1"

if "%TARGETCHOICE%"=="1" set "CHECKMODE=youtube"
if "%TARGETCHOICE%"=="2" set "CHECKMODE=discord"
if "%TARGETCHOICE%"=="3" set "CHECKMODE=both"

echo.
echo  Mode:
echo    [1] Only .bat strategies (fast)
echo    [2] Only generate params
echo    [3] BAT first, then generate (recommended)
echo.
set "RUNMODE="
set /p "RUNMODE=Choice (1-3) [3]: "
if "%RUNMODE%"=="" set "RUNMODE=3"

echo.
echo  Bruteforce level:
echo    [1] Fast   (~50 tests, 5-10 min)
echo    [2] Medium (~150 tests, 20-40 min)
echo    [3] Deep   (~400 tests, 1-2 hours)
echo    [4] Full   (~1000+ tests, 3+ hours)
echo.
set "BFLEVEL="
set /p "BFLEVEL=Choice (1-4) [2]: "
if "%BFLEVEL%"=="" set "BFLEVEL=2"

echo.
echo  Stop after first working?
echo    [1] Yes
echo    [2] No (find all)
echo.
set "STOPCHOICE="
set /p "STOPCHOICE=Choice (1-2) [1]: "
if "%STOPCHOICE%"=="" set "STOPCHOICE=1"
if "%STOPCHOICE%"=="1" set "STOPFIRST=1"
if "%STOPCHOICE%"=="2" set "STOPFIRST=0"

set "INITTIMEOUT=7"
set "CURLTIMEOUT=10"
set "MAXATTEMPTS=2"

echo.
echo  ===========================================================================
echo   SETTINGS:
echo    Check: %CHECKMODE%  Mode: %RUNMODE%  Level: %BFLEVEL%  StopFirst: %STOPFIRST%
echo  ===========================================================================
echo.

set "STARTCONFIRM="
set /p "STARTCONFIRM=Start? (y/n): "
if /i not "%STARTCONFIRM%"=="y" goto mainmenu
goto startbrute

:opt_batonly
cls
echo.
echo  ===========================================================================
echo   TEST .BAT STRATEGIES ONLY
echo  ===========================================================================
echo.

echo  What to check:
echo    [1] YouTube
echo    [2] Discord
echo    [3] Both
echo.
set "TARGETCHOICE="
set /p "TARGETCHOICE=Choice [1]: "
if "%TARGETCHOICE%"=="" set "TARGETCHOICE=1"

if "%TARGETCHOICE%"=="1" set "CHECKMODE=youtube"
if "%TARGETCHOICE%"=="2" set "CHECKMODE=discord"
if "%TARGETCHOICE%"=="3" set "CHECKMODE=both"

set "RUNMODE=1"
set "BFLEVEL=1"
set "STOPFIRST=1"
set "INITTIMEOUT=7"
set "CURLTIMEOUT=10"
set "MAXATTEMPTS=2"

echo.
set "STARTCONFIRM="
set /p "STARTCONFIRM=Start? (y/n): "
if /i not "%STARTCONFIRM%"=="y" goto mainmenu
goto startbrute

:opt_quicktest
cls
echo.
echo  ===========================================================================
echo   QUICK TEST
echo  ===========================================================================
echo.
echo  Select preset:
echo    [1] fake, repeats=6
echo    [2] fake, repeats=11, fooling=ts
echo    [3] multisplit, seqovl=568
echo    [4] multisplit, seqovl=681, fooling=ts
echo    [5] fake,multisplit, seqovl=654, fooling=badseq
echo    [6] fake,multidisorder, fooling=badseq
echo    [0] Enter manually
echo.
set "PRESETNUM="
set /p "PRESETNUM=Choice: "

set "TESTPARAMS="
if "%PRESETNUM%"=="1" set "TESTPARAMS=--dpi-desync=fake --dpi-desync-repeats=6"
if "%PRESETNUM%"=="2" set "TESTPARAMS=--dpi-desync=fake --dpi-desync-repeats=11 --dpi-desync-fooling=ts"
if "%PRESETNUM%"=="3" set "TESTPARAMS=--dpi-desync=multisplit --dpi-desync-split-seqovl=568 --dpi-desync-split-pos=1 --dpi-desync-repeats=8"
if "%PRESETNUM%"=="4" set "TESTPARAMS=--dpi-desync=multisplit --dpi-desync-split-seqovl=681 --dpi-desync-split-pos=1 --dpi-desync-fooling=ts --dpi-desync-repeats=8"
if "%PRESETNUM%"=="5" set "TESTPARAMS=--dpi-desync=fake,multisplit --dpi-desync-split-seqovl=654 --dpi-desync-split-pos=1 --dpi-desync-fooling=badseq --dpi-desync-repeats=8"
if "%PRESETNUM%"=="6" set "TESTPARAMS=--dpi-desync=fake,multidisorder --dpi-desync-split-pos=1,midsld --dpi-desync-fooling=badseq --dpi-desync-repeats=11"
if "%PRESETNUM%"=="0" set /p "TESTPARAMS=Enter params: "

if "%TESTPARAMS%"=="" (
    echo No params selected
    pause
    goto mainmenu
)

echo.
echo  Params: %TESTPARAMS%
echo.

echo  [1/4] Stopping zapret...
taskkill /f /im winws.exe >nul 2>&1
timeout /t 2 /nobreak >nul

echo  [2/4] Starting winws.exe...
start "zapret_quicktest" /min cmd /c ""%BIN%winws.exe" --wf-tcp=80,443 --wf-udp=443 --filter-tcp=80,443 %TESTPARAMS%"

echo  [3/4] Waiting (7 sec)...
timeout /t 7 /nobreak >nul

echo  [4/4] Testing...
echo.

set "CURLTIMEOUT=10"
set "QTRESULT=0"

echo      Checking YouTube...
curl -s -o nul -w "%%{http_code}" --connect-timeout 10 --max-time 10 "https://www.youtube.com" 2>nul | findstr /r "^[23]" >nul
if errorlevel 1 (
    echo      [FAIL] youtube.com
    goto qt_checkdone
)
echo      [OK] youtube.com

curl -s -o nul -w "%%{http_code}" --connect-timeout 10 --max-time 10 "https://i.ytimg.com/vi/dQw4w9WgXcQ/default.jpg" 2>nul | findstr /r "^[23]" >nul
if errorlevel 1 (
    echo      [FAIL] i.ytimg.com
    goto qt_checkdone
)
echo      [OK] i.ytimg.com

echo      Checking Discord...
curl -s -o nul -w "%%{http_code}" --connect-timeout 10 --max-time 10 "https://discord.com" 2>nul | findstr /r "^[23]" >nul
if errorlevel 1 (
    echo      [FAIL] discord.com
    goto qt_checkdone
)
echo      [OK] discord.com

curl -s -o nul -w "%%{http_code}" --connect-timeout 10 --max-time 10 "https://cdn.discordapp.com/embed/avatars/0.png" 2>nul | findstr /r "^[23]" >nul
if errorlevel 1 (
    echo      [FAIL] cdn.discordapp.com
    goto qt_checkdone
)
echo      [OK] cdn.discordapp.com

set "QTRESULT=1"

:qt_checkdone
echo.
if "%QTRESULT%"=="1" (
    echo  ===========================================================================
    echo   [SUCCESS] WORKS!
    echo  ===========================================================================
    echo.
    echo  Params: %TESTPARAMS%
    echo.
    echo  Zapret is currently running with these params.
    echo.
    set "SAVEIT="
    set /p "SAVEIT=Save as .bat file? (y/n): "
    if /i "!SAVEIT!"=="y" (
        set "SAVENAME="
        set /p "SAVENAME=Filename: "
        if not "!SAVENAME!"=="" (
            echo @echo off> "!SAVENAME!.bat"
            echo chcp 866 ^>nul>> "!SAVENAME!.bat"
            echo cd /d "%%~dp0">> "!SAVENAME!.bat"
            echo start "zapret" /min "%%~dp0bin\winws.exe" --wf-tcp=80,443 --wf-udp=443 --filter-tcp=80,443 %TESTPARAMS%>> "!SAVENAME!.bat"
            echo Saved: !SAVENAME!.bat
        )
    )
    echo.
    echo  [1] Keep running and exit
    echo  [2] Stop and return to menu
    echo.
    set "QTEXITCHOICE="
    set /p "QTEXITCHOICE=Choice [1]: "
    if "!QTEXITCHOICE!"=="" set "QTEXITCHOICE=1"
    
    if "!QTEXITCHOICE!"=="1" (
        echo.
        echo  Zapret is running. You can close this window.
        echo.
        pause
        exit /b 0
    ) else (
        taskkill /f /im winws.exe >nul 2>&1
        goto mainmenu
    )
) else (
    echo  ===========================================================================
    echo   [FAIL] Does not work
    echo  ===========================================================================
    taskkill /f /im winws.exe >nul 2>&1
    echo.
    pause
    goto mainmenu
)

:startbrute
cls
echo.
echo  ===========================================================================
echo   BRUTEFORCE STARTED
echo  ===========================================================================
echo   Check: %CHECKMODE%
echo   Mode: %RUNMODE%  Level: %BFLEVEL%
echo  ===========================================================================
echo.

set "TOTALCNT=0"
set "FOUNDCNT=0"

echo. > "%RESFILE%"

if not exist "%BIN%winws.exe" (
    echo [ERROR] winws.exe not found: %BIN%winws.exe
    pause
    goto mainmenu
)

echo [INIT] Stopping current zapret...
taskkill /f /im winws.exe >nul 2>&1
timeout /t 2 /nobreak >nul

echo [TEST] Checking without zapret...
set "CHECKRESULT=0"
call :performcheck
if "%CHECKRESULT%"=="1" (
    echo [OK] Already accessible without zapret!
    pause
    goto mainmenu
)
echo [INFO] Blocked. Starting bruteforce...
echo.

if "%RUNMODE%"=="2" goto bruteforce_phase2

echo ---------------------------------------------------------------------------
echo   PHASE 1: Testing .bat strategies
echo ---------------------------------------------------------------------------
echo.

set "BATCOUNTER=0"
for %%F in (general*.bat) do (
    if "%STOPFIRST%"=="1" (
        if !FOUNDCNT! gtr 0 goto bruteforce_phase1done
    )
    
    set /a BATCOUNTER+=1
    set /a TOTALCNT+=1
    set "CURRENTBAT=%%F"
    
    echo [!BATCOUNTER!] !CURRENTBAT!
    
    taskkill /f /im winws.exe >nul 2>&1
    timeout /t 1 /nobreak >nul
    
    call "!CURRENTBAT!" >nul 2>&1
    timeout /t %INITTIMEOUT% /nobreak >nul
    
    set "STRATEGYWORKS=0"
    for /L %%A in (1,1,%MAXATTEMPTS%) do (
        if "!STRATEGYWORKS!"=="0" (
            set "CHECKRESULT=0"
            call :performcheck
            if "!CHECKRESULT!"=="1" set "STRATEGYWORKS=1"
            if "!STRATEGYWORKS!"=="0" (
                if %%A lss %MAXATTEMPTS% timeout /t 3 /nobreak >nul
            )
        )
    )
    
    if "!STRATEGYWORKS!"=="1" (
        set /a FOUNDCNT+=1
        echo     [SUCCESS] WORKS!
        echo [%DATE% %TIME%] STRATEGY: !CURRENTBAT!>> "%RESFILE%"
        if "%STOPFIRST%"=="1" goto bruteforce_phase1done
    ) else (
        echo     [FAIL]
    )
    echo.
)

:bruteforce_phase1done
echo.
echo [INFO] Phase 1 complete. Found: %FOUNDCNT%
echo.

if "%RUNMODE%"=="1" goto bruteforce_end
if "%STOPFIRST%"=="1" (
    if %FOUNDCNT% gtr 0 goto bruteforce_end
)

:bruteforce_phase2
echo ---------------------------------------------------------------------------
echo   PHASE 2: Generating params
echo ---------------------------------------------------------------------------
echo.

if "%BFLEVEL%"=="1" (
    set "METHODLIST=fake multisplit fake,multisplit"
    set "FOOLLIST=NONE ts badseq"
    set "REPLIST=6 8 11"
    set "SEQLIST=1 568 681"
)
if "%BFLEVEL%"=="2" (
    set "METHODLIST=fake split multisplit fake,split fake,multisplit fake,multidisorder"
    set "FOOLLIST=NONE ts badseq md5sig"
    set "REPLIST=6 8 10 11"
    set "SEQLIST=1 2 568 654 681 772"
)
if "%BFLEVEL%"=="3" (
    set "METHODLIST=fake split disorder multisplit multidisorder fake,split fake,multisplit fake,multidisorder fakedsplit"
    set "FOOLLIST=NONE ts badseq md5sig badsum datanoack"
    set "REPLIST=4 6 8 10 11 12"
    set "SEQLIST=1 2 3 336 568 600 654 681 700 772 852"
)
if "%BFLEVEL%"=="4" (
    set "METHODLIST=fake split disorder multisplit multidisorder fake,split fake,disorder fake,multisplit fake,multidisorder fakedsplit fakeddisorder syndata"
    set "FOOLLIST=NONE ts badseq md5sig badsum datanoack hopbyhop"
    set "REPLIST=2 4 6 8 10 11 12 15 20"
    set "SEQLIST=1 2 3 50 100 200 336 500 568 600 654 681 700 772 800 852 1000 1460"
)

echo [INFO] Level %BFLEVEL%
echo.

for %%M in (%METHODLIST%) do (
    for %%F in (%FOOLLIST%) do (
        for %%R in (%REPLIST%) do (
            if "%STOPFIRST%"=="1" (
                if !FOUNDCNT! gtr 0 goto bruteforce_end
            )
            
            set /a TOTALCNT+=1
            set "CURRENTPARAMS=--dpi-desync=%%M --dpi-desync-repeats=%%R"
            
            if /i not "%%F"=="NONE" (
                set "CURRENTPARAMS=!CURRENTPARAMS! --dpi-desync-fooling=%%F"
            )
            
            echo %%M | findstr /i "split" >nul
            if not errorlevel 1 (
                set "CURRENTPARAMS=!CURRENTPARAMS! --dpi-desync-split-pos=1"
            )
            
            echo [!TOTALCNT!] %%M / %%F / r=%%R
            
            taskkill /f /im winws.exe >nul 2>&1
            timeout /t 1 /nobreak >nul
            
            start "ztest" /min cmd /c ""%BIN%winws.exe" --wf-tcp=80,443 --wf-udp=443 --filter-tcp=80,443 !CURRENTPARAMS!"
            timeout /t %INITTIMEOUT% /nobreak >nul
            
            set "STRATEGYWORKS=0"
            for /L %%A in (1,1,%MAXATTEMPTS%) do (
                if "!STRATEGYWORKS!"=="0" (
                    set "CHECKRESULT=0"
                    call :performcheck
                    if "!CHECKRESULT!"=="1" set "STRATEGYWORKS=1"
                    if "!STRATEGYWORKS!"=="0" (
                        if %%A lss %MAXATTEMPTS% timeout /t 3 /nobreak >nul
                    )
                )
            )
            
            if "!STRATEGYWORKS!"=="1" (
                set /a FOUNDCNT+=1
                echo     [SUCCESS]
                echo [%DATE% %TIME%] PARAMS: !CURRENTPARAMS!>> "%RESFILE%"
                if "%STOPFIRST%"=="1" goto bruteforce_end
            ) else (
                echo     [FAIL]
            )
        )
    )
)

if %BFLEVEL% geq 2 (
    echo.
    echo [PHASE 2.2] Multisplit + seqovl...
    echo.
    
    for %%S in (%SEQLIST%) do (
        for %%F in (NONE ts badseq) do (
            if "%STOPFIRST%"=="1" (
                if !FOUNDCNT! gtr 0 goto bruteforce_end
            )
            
            set /a TOTALCNT+=1
            set "CURRENTPARAMS=--dpi-desync=multisplit --dpi-desync-split-seqovl=%%S --dpi-desync-split-pos=1 --dpi-desync-repeats=8"
            
            if /i not "%%F"=="NONE" (
                set "CURRENTPARAMS=!CURRENTPARAMS! --dpi-desync-fooling=%%F"
            )
            
            echo [!TOTALCNT!] multisplit seqovl=%%S fool=%%F
            
            taskkill /f /im winws.exe >nul 2>&1
            timeout /t 1 /nobreak >nul
            
            start "ztest" /min cmd /c ""%BIN%winws.exe" --wf-tcp=80,443 --wf-udp=443 --filter-tcp=80,443 !CURRENTPARAMS!"
            timeout /t %INITTIMEOUT% /nobreak >nul
            
            set "STRATEGYWORKS=0"
            for /L %%A in (1,1,%MAXATTEMPTS%) do (
                if "!STRATEGYWORKS!"=="0" (
                    set "CHECKRESULT=0"
                    call :performcheck
                    if "!CHECKRESULT!"=="1" set "STRATEGYWORKS=1"
                    if "!STRATEGYWORKS!"=="0" (
                        if %%A lss %MAXATTEMPTS% timeout /t 3 /nobreak >nul
                    )
                )
            )
            
            if "!STRATEGYWORKS!"=="1" (
                set /a FOUNDCNT+=1
                echo     [SUCCESS]
                echo [%DATE% %TIME%] PARAMS: !CURRENTPARAMS!>> "%RESFILE%"
                if "%STOPFIRST%"=="1" goto bruteforce_end
            ) else (
                echo     [FAIL]
            )
        )
    )
)

:bruteforce_end

echo.
echo ===========================================================================
echo   RESULTS
echo ===========================================================================
echo   Total tests:   %TOTALCNT%
echo   Found working: %FOUNDCNT%
echo ===========================================================================

if %FOUNDCNT% gtr 0 (
    echo.
    echo   Working configs:
    echo   ----------------
    type "%RESFILE%"
    echo.
    echo   Saved to: %RESFILE%
    echo.
    echo ===========================================================================
    echo   WORKING STRATEGY IS CURRENTLY RUNNING!
    echo ===========================================================================
    echo.
    echo   [1] Keep running and exit (recommended)
    echo   [2] Stop and return to menu
    echo.
    set "EXITCHOICE="
    set /p "EXITCHOICE=Choice [1]: "
    if "%EXITCHOICE%"=="" set "EXITCHOICE=1"
    
    if "%EXITCHOICE%"=="1" (
        echo.
        echo   Zapret is running. You can close this window.
        echo   To stop zapret later, run this script again or use Task Manager.
        echo.
        pause
        exit /b 0
    ) else (
        taskkill /f /im winws.exe >nul 2>&1
        goto mainmenu
    )
) else (
    taskkill /f /im winws.exe >nul 2>&1
    echo.
    echo   Nothing found.
    echo.
    echo   Try:
    echo   1. Enable Secure DNS in browser
    echo   2. Try level 3 or 4
    echo   3. Update lists folder
    echo   4. Maybe need VPN
    echo.
    pause
    goto mainmenu
)

:performcheck
set "CHECKRESULT=0"
set "YTOK=0"
set "DCOK=0"

if "%CHECKMODE%"=="youtube" goto check_youtube
if "%CHECKMODE%"=="discord" goto check_discord
if "%CHECKMODE%"=="both" goto check_youtube
goto check_done

:check_youtube
curl -s -o nul -w "%%{http_code}" --connect-timeout %CURLTIMEOUT% --max-time %CURLTIMEOUT% "https://www.youtube.com" 2>nul | findstr /r "^[23]" >nul
if errorlevel 1 goto check_yt_done

curl -s -o nul -w "%%{http_code}" --connect-timeout %CURLTIMEOUT% --max-time %CURLTIMEOUT% "https://i.ytimg.com/vi/dQw4w9WgXcQ/default.jpg" 2>nul | findstr /r "^[23]" >nul
if errorlevel 1 goto check_yt_done

set "YTOK=1"

:check_yt_done
if "%CHECKMODE%"=="youtube" goto check_done
goto check_discord

:check_discord
curl -s -o nul -w "%%{http_code}" --connect-timeout %CURLTIMEOUT% --max-time %CURLTIMEOUT% "https://discord.com" 2>nul | findstr /r "^[23]" >nul
if errorlevel 1 goto check_dc_done

curl -s -o nul -w "%%{http_code}" --connect-timeout %CURLTIMEOUT% --max-time %CURLTIMEOUT% "https://cdn.discordapp.com/embed/avatars/0.png" 2>nul | findstr /r "^[23]" >nul
if errorlevel 1 goto check_dc_done

set "DCOK=1"

:check_dc_done
goto check_done

:check_done
if "%CHECKMODE%"=="youtube" (
    if "%YTOK%"=="1" set "CHECKRESULT=1"
    goto check_return
)
if "%CHECKMODE%"=="discord" (
    if "%DCOK%"=="1" set "CHECKRESULT=1"
    goto check_return
)
if "%CHECKMODE%"=="both" (
    if "%YTOK%"=="1" (
        if "%DCOK%"=="1" set "CHECKRESULT=1"
    )
    goto check_return
)

:check_return
goto :eof
