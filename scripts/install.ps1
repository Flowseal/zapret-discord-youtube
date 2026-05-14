#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Установщик zapret-discord-youtube для Windows.

.DESCRIPTION
  Однострочник:
  irm https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/main/scripts/install.ps1 | iex

  Локально:
  .\scripts\install.ps1 -DryRun

  Скачивает последний релизный .zip с GitHub, распаковывает в каталог без кириллицы в пути
  (см. README репозитория). Снимает блокировку «из интернета» с распакованных файлов.

  По желанию регистрирует команду zapret так же, как пункт 12 в service.bat (utils\zapret_cli_shim.ps1).
#>

function Select-ZapretWindowsAssetFromRelease {
  param([Parameter(Mandatory = $true)][object]$Release)
  $assets = @($Release.assets)
  if (-not $assets -or $assets.Count -eq 0) { return $null }

  $zip = $assets | Where-Object { $_.name -match '^zapret-discord-youtube-.+\.zip$' } | Select-Object -First 1
  if ($zip) { return $zip }

  $rar = $assets | Where-Object { $_.name -match '^zapret-discord-youtube-.+\.rar$' } | Select-Object -First 1
  if ($rar) { return $rar }

  return $null
}

function Get-ZapretSafeInstallDirectory {
  <# Рекомендация README: путь без кириллицы и спецсимволов. #>
  if ($env:USERPROFILE -cmatch '[^\x00-\x7F]') {
    return Join-Path $env:SystemDrive 'zapret-discord-youtube'
  }
  return Join-Path $env:USERPROFILE 'zapret-discord-youtube'
}

function Invoke-ZapretCliShim {
  <# Та же регистрация, что в service.bat (п. 12) — через utils\zapret_cli_shim.ps1. #>
  param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('install')]
    [string]$Action,
    [Parameter(Mandatory = $true)]
    [string]$InstallRoot
  )
  $root = $InstallRoot.TrimEnd('\')
  $helper = Join-Path $root 'utils\zapret_cli_shim.ps1'
  if (-not (Test-Path -LiteralPath $helper)) {
    throw "Не найден файл: $helper. Нужен архив релиза с utils\zapret_cli_shim.ps1 или зарегистрируйте zapret вручную: service.bat → пункт 12."
  }
  & $helper -Action $Action -ServiceRoot $root
  if ($LASTEXITCODE -ne 0) {
    throw "zapret_cli_shim.ps1 завершился с кодом $LASTEXITCODE"
  }
}

function Install-ZapretDiscordYoutube {
  param(
    [switch]$Help,
    [switch]$Version,
    [string]$Channel = 'stable',
    [string]$Repo = 'Flowseal/zapret-discord-youtube',
    [switch]$DryRun,
    [switch]$RegisterZapretCommand,
    [switch]$SkipRegisterZapretCommand
  )

  $ErrorActionPreference = 'Stop'

  $InstallerVersion = '1.0.0'
  $LatestReleaseApiUrl = "https://api.github.com/repos/$Repo/releases/latest"

  function Write-Info([string]$Message) { Write-Host "-> $Message" -ForegroundColor Cyan }
  function Write-Ok([string]$Message) { Write-Host "OK $Message" -ForegroundColor Green }
  function Write-WarnMsg([string]$Message) { Write-Host "!  $Message" -ForegroundColor Yellow }
  function Write-Err([string]$Message) { Write-Host "x  $Message" -ForegroundColor Red }

  function Show-Usage {
    @"
zapret-discord-youtube — установщик (Windows)

Использование:
  install.ps1 [-Channel stable] [-Repo owner/repo] [-DryRun] [-Help] [-Version]
              [-RegisterZapretCommand | -SkipRegisterZapretCommand]

  Без этих ключей после установки спрашивается, добавлять ли команду zapret в PATH (как в service.bat → 12).

Примеры:
  irm https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/main/scripts/install.ps1 | iex
  .\scripts\install.ps1 -DryRun
"@
  }

  if ($Help) { Show-Usage; return }
  if ($Version) { Write-Output "zapret-discord-youtube-installer $InstallerVersion"; return }
  if ($Channel -ne 'stable') { Write-Err 'Поддерживается только -Channel stable.'; return }
  if ($env:OS -ne 'Windows_NT') { Write-Err 'Этот установщик только для Windows.'; return }

  $arch = "$($env:PROCESSOR_ARCHITECTURE)".ToLowerInvariant()
  if (-not $arch) {
    try { $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant() } catch { $arch = '' }
  }
  if ($arch -notin @('x64', 'amd64')) {
    Write-Err "Неподдерживаемая архитектура: $arch (нужен Windows x64)."
    return
  }

  Write-Ok 'Платформа: windows/x64'

  $release = $null
  $releaseTag = ''
  $assetName = ''
  $assetUrl = ''
  $assetDigest = ''

  try {
    $release = Invoke-RestMethod -Uri $LatestReleaseApiUrl -UseBasicParsing
    $releaseTag = ($release.tag_name -replace '^v', '')
    $selected = Select-ZapretWindowsAssetFromRelease -Release $release
    if ($selected) {
      $assetName = $selected.name
      $assetUrl = $selected.browser_download_url
      if ($selected.digest) { $assetDigest = ($selected.digest -replace '^sha256:', '') }
    }
  } catch {
    Write-WarnMsg "Не удалось запросить API релиза: $($_.Exception.Message)"
  }

  if (-not $assetUrl) {
    Write-Err 'В последнем релизе нет подходящего .zip/.rar для zapret-discord-youtube.'
    return
  }

  Write-Ok "Релиз $releaseTag : $assetName"

  $tmpFile = Join-Path $env:TEMP $assetName
  $installDir = Get-ZapretSafeInstallDirectory

  if ($DryRun) {
    Write-Output "DRY RUN: скачать $assetUrl -> $tmpFile"
    Write-Output "DRY RUN: распаковать в `"$installDir`""
    if ($assetDigest) { Write-Output "DRY RUN: проверить SHA256 $assetDigest" }
    $shimDir = Join-Path $env:LOCALAPPDATA 'zapret-discord-youtube-cli'
    Write-Output "DRY RUN: при согласии — utils\zapret_cli_shim.ps1 -Action install; shim: `"$shimDir`" + PATH пользователя"
    return
  }

  Write-Info "Скачивание $assetName"
  Invoke-WebRequest -Uri $assetUrl -OutFile $tmpFile -UseBasicParsing

  if ($assetDigest) {
    $fileHash = (Get-FileHash -Path $tmpFile -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($fileHash -ne $assetDigest.ToLowerInvariant()) {
      Write-Err "SHA256 не совпадает для $assetName"
      Write-Err "Ожидалось: $assetDigest"
      Write-Err "Получено:   $fileHash"
      return
    }
    Write-Ok 'Целостность проверена (sha256)'
  } else {
    Write-WarnMsg "Для $assetName нет digest в API — проверка SHA256 пропущена."
  }

  if ($assetName -notlike '*.zip') {
    Write-Err "Автораспаковка поддержана только для .zip. Скачан: $assetName — распакуйте вручную."
    Write-Output "Файл: $tmpFile"
    return
  }

  Write-Info "Распаковка в `"$installDir`""
  if (Test-Path $installDir) {
    Remove-Item -LiteralPath $installDir -Recurse -Force
  }
  $null = New-Item -ItemType Directory -Path $installDir -Force
  Expand-Archive -LiteralPath $tmpFile -DestinationPath $installDir -Force

  Get-ChildItem -LiteralPath $installDir -Recurse -File -ErrorAction SilentlyContinue | Unblock-File
  Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue

  Write-Output ''
  Write-Output 'Готово. Дальше по README: Secure DNS, затем general*.bat или service.bat.'
  Write-Output "Каталог: `"$installDir`""
  $serviceBat = Join-Path $installDir 'service.bat'
  if (Test-Path $serviceBat) {
    Write-Output "Службы и обновления: `"$serviceBat`""
  }

  $doRegister = $false
  if ($RegisterZapretCommand -and $SkipRegisterZapretCommand) {
    Write-WarnMsg 'Указаны и -RegisterZapretCommand, и -SkipRegisterZapretCommand — регистрация команды пропущена.'
  } elseif ($RegisterZapretCommand) {
    $doRegister = $true
  } elseif (-not $SkipRegisterZapretCommand) {
    Write-Output ''
    try {
      $answer = Read-Host 'Зарегистрировать команду zapret в терминале (запуск service.bat)? [y/N]'
      if ($null -ne $answer -and ($answer.Trim() -match '^[yYдД]')) {
        $doRegister = $true
      }
    } catch {
      Write-WarnMsg 'Ввод недоступен — команда zapret не зарегистрирована. Повторите с -RegisterZapretCommand при необходимости.'
    }
  }

  if ($doRegister) {
    if (-not (Test-Path -LiteralPath $serviceBat)) {
      Write-WarnMsg 'Файл service.bat не найден — регистрация zapret отменена.'
    } else {
      try {
        Invoke-ZapretCliShim -Action install -InstallRoot $installDir
        Write-Ok 'Команда zapret зарегистрирована (обновите окно терминала или откройте новое, затем введите: zapret)'
      } catch {
        Write-Err "Не удалось зарегистрировать zapret: $($_.Exception.Message)"
      }
    }
  }
}

if ($MyInvocation.InvocationName -ne '.') {
  Install-ZapretDiscordYoutube @args
}
