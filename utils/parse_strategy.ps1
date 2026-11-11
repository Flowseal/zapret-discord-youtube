# Extract winws2 arguments from a general*.bat strategy file for service install.
# Joins bat line continuations, takes everything after winws2.exe",
# expands %BIN% / %LISTS% / %GameFilterTCP% / %GameFilterUDP% from the
# environment (set by service.bat) and writes the result as a single line.
param(
    [Parameter(Mandatory = $true)][string]$BatFile,
    [Parameter(Mandatory = $true)][string]$OutFile
)

$raw = [IO.File]::ReadAllText($BatFile)
$raw = $raw -replace '\^!', '!'            # escaped '!' in bat (fake-tls=!)
$raw = $raw -replace "\^\r?\n", ' '        # line continuations
$raw = $raw -replace '\s+', ' '

$idx = $raw.IndexOf('winws2.exe"')
if ($idx -lt 0) { Write-Error 'winws2.exe launch not found in strategy file'; exit 1 }
$argsLine = $raw.Substring($idx + 'winws2.exe"'.Length).Trim()

$argsLine = [Environment]::ExpandEnvironmentVariables($argsLine)
[IO.File]::WriteAllText($OutFile, $argsLine, [Text.Encoding]::UTF8)
