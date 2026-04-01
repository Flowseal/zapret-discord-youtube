@echo off
cd /d "%~dp0"
set PREMAKE=%~dp0premake5.exe
if not exist "%PREMAKE%" (
    echo Premake not found: %PREMAKE%
    echo Put premake5.exe in interface folder.
    pause
    exit /b 1
)

if not exist "build" mkdir build

if not exist "vendor\imgui-1.92.6\imgui.h" (
    echo ImGui not found at vendor\imgui-1.92.6
    echo Initialize submodule:
    echo git submodule update --init --recursive
    pause
    exit /b 1
)

echo Generating AntiZapret.sln and build\AntiZapret.vcxproj...
"%PREMAKE%" vs2022
if errorlevel 1 (
    echo Premake failed. Try: "%PREMAKE%" vs2019
    pause
    exit /b 1
)

:: Если .user создался в корне — переносим в build
if exist "AntiZapret.vcxproj.user" (
    move /y "AntiZapret.vcxproj.user" "build\"
    echo Moved AntiZapret.vcxproj.user to build\
)

echo.
echo Done. AntiZapret.sln in root, project files in build\
echo Open AntiZapret.sln in this folder.
pause
