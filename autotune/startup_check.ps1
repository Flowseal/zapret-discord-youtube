# startup_check.ps1 - Zapret Startup Health Check
# Runs silently at user logon via Task Scheduler.

# --- Path resolution ---
if ($PSScriptRoot -and $PSScriptRoot -ne '') {
    $scriptDir = $PSScriptRoot
} else {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}
# bin\autotune -> bin -> root
$rootDir = Split-Path (Split-Path $scriptDir -Parent) -Parent

# --- Give network time to initialize ---
Start-Sleep -Seconds 15

# --- Availability checks ---
$testUrls = @(
    "https://www.youtube.com",
    "https://discord.com"
)

$allPassed = $true

# Only run if curl is available
if (-not (Get-Command "curl.exe" -ErrorAction SilentlyContinue)) {
    # No curl - cannot check, exit silently
    exit 0
}

foreach ($url in $testUrls) {
    try {
        $curlArgs = @("-s", "-o", "NUL", "-w", "%{http_code}", "-m", "3",
                      "--connect-timeout", "3", "-L", $url)
        $httpCode = (& curl.exe @curlArgs 2>$null | Out-String).Trim()
        $exit = $LASTEXITCODE

        if (-not ($exit -eq 0 -and $httpCode -match "^[234]\d\d$")) {
            $allPassed = $false
            break
        }
    } catch {
        $allPassed = $false
        break
    }
}

if (-not $allPassed) {
    # Show a notification using Windows Forms MessageBox
    Add-Type -AssemblyName System.Windows.Forms

    $msgResult = [System.Windows.Forms.MessageBox]::Show(
        "Zapret bypass check failed.`nThe DPI parameters on your ISP might have changed.`n`nWould you like to run Autotune to automatically find a new working strategy?",
        "Zapret Health Check",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )

    if ($msgResult -eq [System.Windows.Forms.DialogResult]::Yes) {
        $serviceBat = Join-Path $rootDir "service.bat"
        if (Test-Path $serviceBat) {
            # Launch service.bat with autotune_apply - requests UAC elevation
            Start-Process -FilePath "$serviceBat" `
                -ArgumentList "autotune_apply" `
                -Verb RunAs
        }
    }
}
