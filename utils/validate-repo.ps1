$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$rootDir = Split-Path $PSScriptRoot
$serviceBat = Join-Path $rootDir "service.bat"
$listsDir = Join-Path $rootDir "lists"
$ipsetFile = Join-Path $listsDir "ipset-all.txt"
$generatedListFiles = @(
    "ipset-exclude-user.txt",
    "list-exclude-user.txt",
    "list-general-user.txt"
)
$requiredBootstrapCalls = @(
    "call service.bat status_zapret",
    "call service.bat check_updates",
    "call service.bat load_game_filter",
    "call service.bat load_user_lists"
)
$errors = New-Object System.Collections.Generic.List[string]

function Add-ValidationError {
    param([string]$Message)

    $script:errors.Add($Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

function Write-ValidationInfo {
    param([string]$Message)

    Write-Host "[INFO] $Message" -ForegroundColor DarkCyan
}

function Assert-FileExists {
    param(
        [string]$Path,
        [string]$Label
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Add-ValidationError "$Label missing: $Path"
    }
}

function Get-ServiceIpsetStatus {
    $stdoutFile = Join-Path $env:TEMP ("zapret-validate-" + [System.Guid]::NewGuid().ToString("N") + ".out")
    $stderrFile = Join-Path $env:TEMP ("zapret-validate-" + [System.Guid]::NewGuid().ToString("N") + ".err")

    try {
        $process = Start-Process -FilePath "cmd.exe" `
            -ArgumentList "/d", "/c", ('call "' + $serviceBat + '" status_ipset') `
            -NoNewWindow `
            -Wait `
            -PassThru `
            -RedirectStandardOutput $stdoutFile `
            -RedirectStandardError $stderrFile

        $output = ""
        if (Test-Path -LiteralPath $stdoutFile) {
            $output = (Get-Content -LiteralPath $stdoutFile -Raw).Trim()
        }

        if ($process.ExitCode -ne 0) {
            $stderr = ""
            if (Test-Path -LiteralPath $stderrFile) {
                $stderr = (Get-Content -LiteralPath $stderrFile -Raw).Trim()
            }

            throw "service.bat status_ipset failed with exit code $($process.ExitCode). $stderr"
        }

        return $output
    }
    finally {
        Remove-Item -LiteralPath $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
    }
}

Write-ValidationInfo "Checking root batch layout..."
$rootBatchFiles = Get-ChildItem -LiteralPath $rootDir -Filter "*.bat" -File | Sort-Object Name
$strategyFiles = $rootBatchFiles | Where-Object { $_.Name -notlike "service*" }

if (-not $strategyFiles) {
    Add-ValidationError "No strategy batch files were found in the repository root."
}

$unexpectedRootBatchFiles = $strategyFiles | Where-Object { $_.Name -notlike "general*.bat" }
foreach ($file in $unexpectedRootBatchFiles) {
    Add-ValidationError "Unexpected root batch file '$($file.Name)'. service.bat offers every non-service root .bat as an installable service."
}

Write-ValidationInfo "Checking launcher bootstrap and referenced files..."
$serviceContent = Get-Content -LiteralPath $serviceBat -Raw
foreach ($generatedListFile in $generatedListFiles) {
    if ($serviceContent -notmatch [regex]::Escape($generatedListFile)) {
        Add-ValidationError "service.bat no longer provisions generated user list '$generatedListFile'."
    }
}

foreach ($strategyFile in $strategyFiles) {
    $content = Get-Content -LiteralPath $strategyFile.FullName -Raw

    foreach ($call in $requiredBootstrapCalls) {
        if ($content -notmatch [regex]::Escape($call)) {
            Add-ValidationError "$($strategyFile.Name) is missing bootstrap call '$call'."
        }
    }

    if ($content -notmatch '%BIN%winws\.exe') {
        Add-ValidationError "$($strategyFile.Name) does not launch %BIN%winws.exe."
    }

    $binRefs = [regex]::Matches($content, '%BIN%([^"\s\r\n]+)') |
        ForEach-Object { $_.Groups[1].Value } |
        Sort-Object -Unique
    foreach ($relativePath in $binRefs) {
        $fullPath = Join-Path (Join-Path $rootDir "bin") $relativePath
        Assert-FileExists -Path $fullPath -Label "$($strategyFile.Name) references missing bin asset '$relativePath'"
    }

    $listRefs = [regex]::Matches($content, '%LISTS%([^"\s\r\n]+)') |
        ForEach-Object { $_.Groups[1].Value } |
        Sort-Object -Unique
    foreach ($relativePath in $listRefs) {
        if ($generatedListFiles -contains $relativePath) {
            continue
        }

        $fullPath = Join-Path $listsDir $relativePath
        Assert-FileExists -Path $fullPath -Label "$($strategyFile.Name) references missing list '$relativePath'"
    }
}

Write-ValidationInfo "Checking IPSet status detection through service.bat..."
$originalIpsetExists = Test-Path -LiteralPath $ipsetFile -PathType Leaf
$originalIpsetBytes = $null
if ($originalIpsetExists) {
    $originalIpsetBytes = [System.IO.File]::ReadAllBytes($ipsetFile)
}

try {
    $cases = @(
        @{
            Name = "loaded"
            Expected = "loaded"
            Bytes = [System.Text.Encoding]::ASCII.GetBytes("1.1.1.1/32`r`n")
        },
        @{
            Name = "none"
            Expected = "none"
            Bytes = [System.Text.Encoding]::ASCII.GetBytes("203.0.113.113/32`r`n")
        },
        @{
            Name = "any"
            Expected = "any"
            Bytes = [byte[]]@()
        },
        @{
            Name = "missing"
            Expected = "none"
            Remove = $true
        }
    )

    foreach ($case in $cases) {
        if ($case.ContainsKey("Remove") -and $case["Remove"]) {
            Remove-Item -LiteralPath $ipsetFile -Force -ErrorAction SilentlyContinue
        } else {
            [System.IO.File]::WriteAllBytes($ipsetFile, $case.Bytes)
        }

        $actual = Get-ServiceIpsetStatus
        if ($actual -ne $case.Expected) {
            Add-ValidationError "service.bat status_ipset returned '$actual' for $($case.Name) mode; expected '$($case.Expected)'."
        }
    }
}
finally {
    if ($originalIpsetExists) {
        [System.IO.File]::WriteAllBytes($ipsetFile, $originalIpsetBytes)
    } else {
        Remove-Item -LiteralPath $ipsetFile -Force -ErrorAction SilentlyContinue
    }
}

if ($errors.Count -gt 0) {
    Write-Host ""
    Write-Host "Validation failed with $($errors.Count) error(s)." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Validation completed successfully." -ForegroundColor Green
