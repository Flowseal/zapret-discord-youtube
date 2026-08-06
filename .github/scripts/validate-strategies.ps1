[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Join-Path $PSScriptRoot "..\..")
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$root = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$errors = New-Object System.Collections.Generic.List[string]
$checkedReferences = 0

function Add-ValidationError {
    param(
        [string]$File,
        [string]$Message
    )

    $errors.Add("${File}: ${Message}")
}

function Test-ContainsText {
    param(
        [string]$Content,
        [string]$Expected
    )

    return $Content.IndexOf($Expected, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
}

$requiredRepositoryFiles = @(
    "service.bat",
    ".service/version.txt",
    "bin/winws.exe"
)

foreach ($relativePath in $requiredRepositoryFiles) {
    $fullPath = Join-Path $root $relativePath
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        Add-ValidationError -File $relativePath -Message "required repository file is missing"
    }
}

$strategyFiles = @(
    Get-ChildItem -LiteralPath $root -File |
        Where-Object { $_.Name -like "general*.bat" } |
        Sort-Object -Property Name
)

if ($strategyFiles.Count -eq 0) {
    Add-ValidationError -File "." -Message "no general*.bat strategy files were found"
}

$requiredInitialization = @(
    "call service.bat status_zapret",
    "call service.bat check_updates",
    "call service.bat load_game_filter",
    "call service.bat load_user_lists"
)

# These files are intentionally not tracked. service.bat creates them on first run.
$runtimeGeneratedReferences = @{
    "LISTS|ipset-exclude-user.txt" = $true
    "LISTS|list-exclude-user.txt" = $true
    "LISTS|list-general-user.txt" = $true
}

$referencePattern = [regex]'%(?<scope>BIN|LISTS)%(?<path>[^"\s\^&|<>]+)'

foreach ($strategyFile in $strategyFiles) {
    $relativeStrategyPath = $strategyFile.Name
    $content = Get-Content -LiteralPath $strategyFile.FullName -Raw
    $lines = @($content -split "`r?`n")

    foreach ($requiredLine in $requiredInitialization) {
        if (-not (Test-ContainsText -Content $content -Expected $requiredLine)) {
            Add-ValidationError -File $relativeStrategyPath -Message "missing required initialization: $requiredLine"
        }
    }

    $startIndexes = @()
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match '(?i)^\s*start\s+.*winws\.exe') {
            $startIndexes += $index
        }
    }

    if ($startIndexes.Count -ne 1) {
        Add-ValidationError -File $relativeStrategyPath -Message "expected exactly one start command for winws.exe, found $($startIndexes.Count)"
    }
    else {
        $commandIndex = $startIndexes[0]
        $currentIndex = $commandIndex

        while ($currentIndex -lt $lines.Count) {
            $currentLine = $lines[$currentIndex].TrimEnd()
            $continues = $currentLine.EndsWith('^')

            if (-not $continues) {
                $nextIndex = $currentIndex + 1
                while ($nextIndex -lt $lines.Count -and [string]::IsNullOrWhiteSpace($lines[$nextIndex])) {
                    $nextIndex++
                }

                if ($nextIndex -lt $lines.Count -and $lines[$nextIndex] -match '^\s*--') {
                    Add-ValidationError -File $relativeStrategyPath -Message "line $($currentIndex + 1) is missing a trailing ^ before the next winws argument"
                }
                break
            }

            $currentIndex++
            if ($currentIndex -ge $lines.Count) {
                Add-ValidationError -File $relativeStrategyPath -Message "winws command ends with a dangling ^"
                break
            }

            if ([string]::IsNullOrWhiteSpace($lines[$currentIndex])) {
                Add-ValidationError -File $relativeStrategyPath -Message "blank line found inside the continued winws command at line $($currentIndex + 1)"
                break
            }
        }
    }

    $seenReferences = @{}
    foreach ($match in $referencePattern.Matches($content)) {
        $scope = $match.Groups['scope'].Value.ToUpperInvariant()
        $referencedPath = $match.Groups['path'].Value.Replace('/', '\')
        $referenceKey = "${scope}|${referencedPath}"

        if ($seenReferences.ContainsKey($referenceKey)) {
            continue
        }
        $seenReferences[$referenceKey] = $true
        $checkedReferences++

        if ($runtimeGeneratedReferences.ContainsKey($referenceKey)) {
            continue
        }

        $baseDirectory = if ($scope -eq "BIN") { "bin" } else { "lists" }
        $relativeReferencedPath = Join-Path $baseDirectory $referencedPath
        $fullReferencedPath = Join-Path $root $relativeReferencedPath

        if (-not (Test-Path -LiteralPath $fullReferencedPath -PathType Leaf)) {
            Add-ValidationError -File $relativeStrategyPath -Message "references missing file: $relativeReferencedPath"
        }
    }
}

if ($errors.Count -gt 0) {
    Write-Host "Strategy validation failed with $($errors.Count) error(s):" -ForegroundColor Red
    foreach ($validationError in $errors) {
        Write-Host "  - $validationError" -ForegroundColor Red
    }
    exit 1
}

Write-Host "Strategy validation passed." -ForegroundColor Green
Write-Host "Checked $($strategyFiles.Count) strategy file(s) and $checkedReferences unique file reference(s)."
