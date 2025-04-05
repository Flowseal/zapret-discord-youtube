@echo off
setlocal EnableDelayedExpansion
chcp 65001 > nul
:: UTF-8 для корректных сообщений

:: Пути
set VERSION_FILE=%~dp0.version

:: Конфигурация URL'ов
set "GITHUB_VERSION_URL=https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/main/.service/version.txt"
set "GITHUB_RELEASE_URL=https://github.com/Flowseal/zapret-discord-youtube/releases/tag/"
set "GITHUB_DOWNLOAD_URL=https://github.com/Flowseal/zapret-discord-youtube/releases/latest/download/zapret-discord-youtube-"

:: Получаем текущую локальную версию из .version
if not exist "%VERSION_FILE%" (
    echo [ERROR] Файл .version не найден!
    echo Локальная версия неизвестна.
    goto :exit
)
set /p LOCAL_VERSION=<"%VERSION_FILE%"

echo [INFO] Проверка обновлений...
echo [INFO] Локальная версия: %LOCAL_VERSION%

:: Получение последней версии с GitHub (через PowerShell)
for /f "delims=" %%A in (
    'powershell -Command "(Invoke-WebRequest -Uri \"%GITHUB_VERSION_URL%\" -Headers @{\"Cache-Control\"=\"no-cache\"} -TimeoutSec 5).Content.Trim()" 2^>nul'
) do set "GITHUB_VERSION=%%A"

:: Ошибка при получении
if not defined GITHUB_VERSION (
    echo [ERROR] Не удалось получить последнюю версию. Проверьте интернет-соединение.
    goto :exit
)

echo [INFO] Последняя версия: %GITHUB_VERSION%

:: Сравнение
call :compare_versions "%LOCAL_VERSION%" "%GITHUB_VERSION%"
if "!COMPARE_RESULT!"=="equal" (
    echo [OK] Установлена актуальная версия.
    goto :exit
)

:: Обновление доступно
echo [UPDATE] Доступна новая версия: %GITHUB_VERSION%
echo [INFO] Страница релиза: %GITHUB_RELEASE_URL%%GITHUB_VERSION%

:: Автоматический режим
if /i "%1"=="auto" (
    echo [AUTO] Открытие страницы загрузки...
    start "" "%GITHUB_DOWNLOAD_URL%%GITHUB_VERSION%.rar"
    goto :exit
)

:: Запрос
set /p "CHOICE=Скачать новую версию сейчас? (y/n, по умолчанию y): "
if "!CHOICE!"=="" set "CHOICE=y"

if /i "!CHOICE!"=="y" (
    echo [INFO] Открываем страницу загрузки...
    start "" "%GITHUB_DOWNLOAD_URL%%GITHUB_VERSION%.rar"
) else (
    echo [INFO] Обновление отменено пользователем.
)

:exit
if not "%1"=="soft" pause
endlocal
exit /b

:: --- Функция сравнения версий ---
:compare_versions
setlocal
set "v1=%~1"
set "v2=%~2"

call :normalize_version "%v1%" v1n
call :normalize_version "%v2%" v2n

if %v1n% LSS %v2n% (
    endlocal & set "COMPARE_RESULT=older" & goto :EOF
)
if %v1n% GTR %v2n% (
    endlocal & set "COMPARE_RESULT=newer" & goto :EOF
)
endlocal & set "COMPARE_RESULT=equal"
goto :EOF

:normalize_version
setlocal
set "v=%~1"
set "v=%v:.=%"
set "v=00%v%000"
set "v=%v:~0,9%"
endlocal & set "%~2=%v%"
goto :EOF
