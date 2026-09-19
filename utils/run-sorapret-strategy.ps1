param([Parameter(Mandatory=$true)][string]$Strategy)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$source = Join-Path $root $Strategy
$originalExe = Join-Path $root 'bin\winws.exe'
$customExe = Join-Path $root 'bin\winws-sorapret.exe'
$builder = Join-Path $PSScriptRoot 'build-sorapret-winws.ps1'

if (-not (Test-Path -LiteralPath $source)) { throw "Strategy not found: $Strategy" }

# Rebuild after downloads/updates so the executable code always matches winws.exe.
if (-not (Test-Path -LiteralPath $customExe) -or
    (Get-Item -LiteralPath $customExe).LastWriteTimeUtc -lt (Get-Item -LiteralPath $originalExe).LastWriteTimeUtc) {
    & $builder -Source $originalExe -Target $customExe
}

$content = [IO.File]::ReadAllText($source)
$name = [IO.Path]::GetFileNameWithoutExtension($source)
$content = $content.Replace('winws.exe','winws-sorapret.exe').Replace('%~n0',$name)
$temp = Join-Path $root '.sorapret-launch.bat'
[IO.File]::WriteAllText($temp,$content,(New-Object Text.UTF8Encoding($false)))
try {
    & $env:ComSpec /d /c "`"$temp`""
} finally {
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
}
