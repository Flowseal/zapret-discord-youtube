param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('install', 'uninstall', 'status')]
  [string]$Action,
  # Из service.bat путь передаётся через ZAPRET_CLI_SERVICE_ROOT (обход & ! % в cmd).
  [Parameter(Mandatory = $false)]
  [string]$ServiceRoot = ''
)

$ErrorActionPreference = 'Stop'
try {
  $rawRoot = if (-not [string]::IsNullOrWhiteSpace($ServiceRoot)) {
    $ServiceRoot
  } elseif (-not [string]::IsNullOrWhiteSpace($env:ZAPRET_CLI_SERVICE_ROOT)) {
    $env:ZAPRET_CLI_SERVICE_ROOT
  } else {
    throw 'Укажите -ServiceRoot или задайте переменную окружения ZAPRET_CLI_SERVICE_ROOT (каталог с service.bat).'
  }

  $ServiceRoot = ($rawRoot.TrimEnd('\', '/') -replace '[\\/]+$', '').Trim()

  $shimDir = Join-Path $env:LOCALAPPDATA 'zapret-discord-youtube-cli'
  $cmdPath = Join-Path $shimDir 'zapret.cmd'

  function Get-ZapretShimCmdText {
    param([Parameter(Mandatory = $true)][string]$Root)
    return @(
      '@echo off',
      "set `"ZAPRET_HOME=$Root`"",
      'cd /d "%ZAPRET_HOME%"',
      'call service.bat'
    ) -join "`r`n"
  }

  switch ($Action) {
    'status' {
      if (-not (Test-Path -LiteralPath $cmdPath)) {
        Write-Output 'disabled'
        return
      }
      $lines = [System.IO.File]::ReadAllLines($cmdPath, [System.Text.UTF8Encoding]::new($false))
      if ($lines.Count -lt 2) {
        Write-Output 'path mismatch'
        return
      }
      $expected = "set `"ZAPRET_HOME=$ServiceRoot`""
      if ($lines[1] -eq $expected) {
        Write-Output 'enabled'
      } else {
        Write-Output 'path mismatch'
      }
    }
    'install' {
      if (-not (Test-Path -LiteralPath (Join-Path $ServiceRoot 'service.bat'))) {
        throw "service.bat not found under ServiceRoot: $ServiceRoot"
      }
      $null = New-Item -ItemType Directory -Path $shimDir -Force
      $text = Get-ZapretShimCmdText -Root $ServiceRoot
      [System.IO.File]::WriteAllText($cmdPath, $text, [System.Text.UTF8Encoding]::new($false))

      $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
      $segments = @()
      if (-not [string]::IsNullOrWhiteSpace($userPath)) {
        $normShim = $shimDir.TrimEnd('\')
        $segments = @(
          $userPath.Split(';', [StringSplitOptions]::RemoveEmptyEntries) |
            Where-Object { $_.TrimEnd('\') -ne $normShim }
        )
      }
      $newPath = ($segments + $shimDir) -join ';'
      [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
      if (($env:Path -split ';' | ForEach-Object { $_.TrimEnd('\') }) -notcontains $shimDir.TrimEnd('\')) {
        $env:Path = $env:Path.TrimEnd(';') + ';' + $shimDir
      }
      Write-Output 'OK'
    }
    'uninstall' {
      $normShim = $shimDir.TrimEnd('\')
      $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
      $segments = @()
      if (-not [string]::IsNullOrWhiteSpace($userPath)) {
        $segments = @(
          $userPath.Split(';', [StringSplitOptions]::RemoveEmptyEntries) |
            Where-Object { $_.TrimEnd('\') -ne $normShim }
        )
      }
      [Environment]::SetEnvironmentVariable('Path', ($segments -join ';'), 'User')

      if (Test-Path -LiteralPath $shimDir) {
        Remove-Item -LiteralPath $shimDir -Recurse -Force -ErrorAction SilentlyContinue
      }
      Write-Output 'OK'
    }
  }
} catch {
  Write-Error $_.Exception.Message
  exit 1
}
exit 0
