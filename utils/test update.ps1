param([switch]$StaticOnly)
$ErrorActionPreference = 'Stop'
$updater = Join-Path $PSScriptRoot 'update.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($updater, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors -join "`n") }
# Load only function declarations; never execute the network/runtime entry point.
foreach ($definition in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($definition.Extent.Text))
}
$script:checks = 0
function Assert($Condition, [string]$Label) {
    if (-not $Condition) { throw "FAILED: $Label" }
    $script:checks++
    Write-Host "PASS: $Label"
}
function Assert-Throws([scriptblock]$Action, [string]$Label) {
    $thrown = $false
    try { & $Action | Out-Null } catch { $thrown = $true }
    Assert $thrown $Label
}
Assert (Test-IsNewerVersion 'v1.10.2a' '1.10.2') 'letter suffix'
Assert (Test-IsNewerVersion '1.11.0' '1.9.9') 'numeric version comparison'
Assert (-not (Test-IsNewerVersion '1.10.2' '1.10.2')) 'equal version'
Assert (-not (Test-IsNewerVersion '1.9.9' '1.10.2')) 'older version'
Assert-Throws { Test-IsNewerVersion 'invalid' '1.10.2' } 'invalid version'
Assert ((Quote-ProcessArgument 'C:\path with spaces\') -ceq '"C:\path with spaces\\"') 'trailing backslash quoting'
Assert ((Quote-ProcessArgument 'a"b') -ceq '"a\"b"') 'embedded quote'
$digest = 'a' * 64
Assert ((Get-AssetHash ([pscustomobject]@{digest = "sha256:$digest"})) -eq $digest) 'GitHub digest'
Assert ($null -eq (Get-AssetHash ([pscustomobject]@{}))) 'absent digest permits checksum fallback'
Assert-Throws { Get-AssetHash ([pscustomobject]@{digest = 'sha256:bad'}) } 'malformed digest rejected'
function Get-CimInstance { [pscustomobject]@{ PathName = '"C:\zapret\bin\winws.exe" --test' } }
Assert ($null -ne (Get-LocalService 'C:\zapret\bin\winws.exe')) 'local service ownership'
Assert-Throws { Get-LocalService 'C:\other\bin\winws.exe' } 'foreign service rejected'
$testRoot = Join-Path $env:TEMP ('zapret-update-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$modeHarness = @'
param($Updater, $Mode, $Actions)
function Invoke-RestMethod {
    $version = if ($Mode -eq 'equal') { '1.10.2' } elseif ($Mode -eq 'older') { '1.9.0' } else { '1.10.3' }
    $assets = @()
    if ($Mode -in @('decline', 'noninteractive', 'no-hash')) {
        $hash = if ($Mode -eq 'no-hash') { $null } else { 'sha256:' + ('a' * 64) }
        $assets = @([pscustomobject]@{ name = 'zapret-discord-youtube-1.10.3.zip'; digest = $hash })
    }
    [pscustomobject]@{tag_name = $version; assets = $assets}
}
function Start-Process { param($FilePath) Add-Content -LiteralPath $Actions -Value "open:$FilePath" }
function Invoke-WebRequest { throw 'Unexpected download in mode test' }
function Read-Host { Add-Content -LiteralPath $Actions -Value 'prompt'; return 'N' }
$arguments = @{ CurrentVersion = '1.10.2'; InstallDir = $PSScriptRoot }
if ($Mode -in @('decline', 'noninteractive', 'no-hash')) { $arguments.Install = $true }
else { $arguments.OpenReleasePage = $true }
if ($Mode -eq 'noninteractive') { $arguments.NonInteractive = $true }
& $Updater @arguments
exit $LASTEXITCODE
'@
$harnessPath = Join-Path $testRoot 'mode-test.ps1'
[IO.File]::WriteAllText($harnessPath, $modeHarness)
$engine = (Get-Process -Id $PID).Path
foreach ($mode in @('page', 'equal', 'older', 'decline', 'noninteractive', 'no-hash')) {
    $actions = Join-Path $testRoot "$mode.actions"
    $result = & $engine -NoProfile -ExecutionPolicy Bypass -File $harnessPath $updater $mode $actions 2>&1
    $code = $LASTEXITCODE
    Assert ($code -eq $(if ($mode -in @('noninteractive', 'no-hash')) { 1 } else { 0 })) "$mode check exit code"
    $recorded = if (Test-Path -LiteralPath $actions) { [IO.File]::ReadAllText($actions).Trim() } else { '' }
    $expected = if ($mode -eq 'page') { 'open:https://github.com/Flowseal/zapret-discord-youtube/releases/tag/1.10.3' } elseif ($mode -eq 'decline') { 'prompt' } else { '' }
    Assert ($recorded -ceq $expected) "$mode external actions"
}
if ($StaticOnly) { Write-Host "$script:checks checks passed. Fixtures: $testRoot"; exit 0 }
if ($env:OS -ne 'Windows_NT') { throw 'Installation tests require Windows; use -StaticOnly elsewhere.' }
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
function Write-Fixture([string]$Path, [string]$Content) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Content)
}
function Run-Case([string]$Name, [string]$Mode) {
    $caseRoot = Join-Path $testRoot $Name
    $install = Join-Path $caseRoot 'install with spaces'
    $bundle = Join-Path $caseRoot 'source\release'
    Write-Fixture (Join-Path $install 'service.bat') 'old service'
    Write-Fixture (Join-Path $install 'z-locked.txt') 'old locked'
    Write-Fixture (Join-Path $install 'lists\list-general-user.txt') 'my domains'
    Write-Fixture (Join-Path $install 'utils\auto_update.enabled') 'enabled'
    Write-Fixture (Join-Path $bundle 'service.bat') 'set "LOCAL_VERSION=1.10.3"'
    Write-Fixture (Join-Path $bundle 'general.bat') '@echo off'
    Write-Fixture (Join-Path $bundle 'bin\winws.exe') 'fake executable - never run'
    Write-Fixture (Join-Path $bundle 'utils\update.ps1') '# fake updater - never run'
    Write-Fixture (Join-Path $bundle 'lists\list-general-user.txt') 'release domains'
    Write-Fixture (Join-Path $bundle 'utils\check_updates.enabled') 'enabled'
    Write-Fixture (Join-Path $bundle 'z-locked.txt') 'new locked'
    if ($Mode -eq 'missing-updater') { Remove-Item -LiteralPath (Join-Path $bundle 'utils\update.ps1') }
    $zip = Join-Path $caseRoot 'release.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory((Split-Path -Parent $bundle), $zip)
    if ($Mode -eq 'unsafe') {
        $archive = [IO.Compression.ZipFile]::Open($zip, 'Update')
        try { $archive.CreateEntry('../escape.txt') | Out-Null } finally { $archive.Dispose() }
    }
    $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
    if ($Mode -eq 'hash') { $hash = '0' * 64 }
    $version = if ($Mode -eq 'version') { '1.10.4' } else { '1.10.3' }
    $handle = $null
    if ($Mode -eq 'locked') {
        # Allow backup reads but deny replacement to force a real Windows sharing violation.
        $handle = [IO.File]::Open((Join-Path $install 'z-locked.txt'), 'Open', 'Read', 'Read')
    }
    try {
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $updater -Apply -InstallDir $install -PackagePath $zip -ExpectedHash $hash -ReleaseVersion $version -SkipRuntimeControl -NonInteractive 2>&1
        $code = $LASTEXITCODE
    } finally { if ($handle) { $handle.Dispose() } }
    $output | Set-Content -LiteralPath (Join-Path $caseRoot 'result.txt')
    Assert ($code -eq $(if ($Mode -eq 'ok') { 0 } else { 1 })) "$Name exit code"
    Assert ((Get-Content -LiteralPath (Join-Path $install 'lists\list-general-user.txt') -Raw) -eq 'my domains') "$Name preserves user list"
    Assert (Test-Path -LiteralPath (Join-Path $install 'utils\auto_update.enabled')) "$Name preserves enabled marker"
    Assert (-not (Test-Path -LiteralPath (Join-Path $install 'utils\check_updates.enabled'))) "$Name preserves absent marker"
    $serviceText = Get-Content -LiteralPath (Join-Path $install 'service.bat') -Raw
    if ($Mode -eq 'ok') {
        Assert ($serviceText -eq 'set "LOCAL_VERSION=1.10.3"') "$Name installs files"
        $backups = @(Get-ChildItem -LiteralPath $caseRoot -Directory -Filter 'install with spaces.backup-*')
        Assert ($backups.Count -eq 1) "$Name creates backup"
        Assert ((Get-Content -LiteralPath (Join-Path $backups[0].FullName 'service.bat') -Raw) -eq 'old service') "$Name backup content"
    } else {
        Assert ($serviceText -eq 'old service') "$Name retains/restores old files"
        Assert (-not (Test-Path -LiteralPath (Join-Path $install 'bin\winws.exe'))) "$Name leaves no new executable"
    }
    if ($Mode -eq 'locked') { Assert (($output -join "`n") -match 'Rollback incomplete') 'locked rollback reports failure explicitly' }
}
try {
    Run-Case 'successful-install' 'ok'
    Run-Case 'bad-checksum' 'hash'
    Run-Case 'wrong-version' 'version'
    Run-Case 'path-traversal' 'unsafe'
    Run-Case 'incompatible-release' 'missing-updater'
    Run-Case 'locked-target' 'locked'
    Write-Host "$script:checks checks passed. Fixtures and logs: $testRoot"
} catch {
    Write-Host "Fixtures retained: $testRoot"
    throw
}
