$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'utils\aion2-checks.ps1')
$checks = 0
function Assert-True([bool]$condition,[string]$message) {
    if (-not $condition) { throw "FAIL: $message" }
    $script:checks++
}
function Assert-Equal($expected,$actual,[string]$message) {
    if ($expected -ne $actual) { throw "FAIL: $message (expected=$expected actual=$actual)" }
    $script:checks++
}
# Parse every new PowerShell file using the actual PowerShell parser.
foreach ($file in @('utils\aion2-checks.ps1','utils\test aion2.ps1',$MyInvocation.MyCommand.Path)) {
    $filePath = if ([IO.Path]::IsPathRooted($file)) { $file } else { Join-Path $root $file }
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($filePath,[ref]$tokens,[ref]$errors)
    Assert-Equal 0 $(if ($null -eq $errors) { 0 } else { @($errors).Count }) "PowerShell parse: $file"
}
# Example and edge-case tests
Assert-True (Test-AionIPv4InCidr '193.202.112.122' '193.202.112.0/24') 'inside /24'
Assert-True (-not (Test-AionIPv4InCidr '193.202.113.1' '193.202.112.0/24')) 'outside /24'
Assert-True (Test-AionIPv4InCidr '0.0.0.0' '0.0.0.0/0') '/0 includes everything'
Assert-True (Test-AionIPv4InCidr '255.255.255.255' '255.255.255.255/32') '/32 exact'
Assert-True (-not (Test-AionIPv4InCidr '256.1.1.1' '0.0.0.0/0')) 'invalid ip'
Assert-Equal 'included' (Test-AionIPSet '193.202.112.122' @('193.202.112.0/24','34.117.142.0/24')) 'known range'
Assert-Equal 'excluded' (Test-AionIPSet '1.2.3.4' @('193.202.112.0/24')) 'range exclusion'
Assert-Equal 'any' (Test-AionIPSet '1.2.3.4' @('')) 'empty ipset any'
Assert-Equal 'none' (Test-AionIPSet '1.2.3.4' @('203.0.113.113/32')) 'placeholder none'
Assert-True (Test-AionPortInRange 13328 '13328,443') 'single port'
Assert-True (Test-AionPortInRange 13328 '13000-14000') 'range port'
Assert-True (-not (Test-AionPortInRange 13328 '443,8443')) 'port excluded'
Assert-True (-not (Test-AionPortInRange 13328 '12')) 'disabled game filter'
$stats = Get-AionStats -Measurements @([double]10,[double]20,[double]30,[double]40) -Attempts 5
Assert-Equal 80 $stats.SuccessPct 'loss percentage'
Assert-Equal 25 $stats.AvgMs 'average'
Assert-Equal 25 $stats.MedianMs 'median'
Assert-Equal 40 $stats.P95Ms 'nearest-rank P95'
$none = Get-AionStats -Measurements @() -Attempts 8
Assert-Equal 0 $none.SuccessPct 'no TCP success'
Assert-True ($null -eq $none.P95Ms) 'P95 not fabricated on failure'
$rows = @(
    [pscustomobject]@{Config='fast-fail';Eligible=$false;DiscordOK=3;AionTcpSuccessPct=100;AionTcpP95Ms=1},
    [pscustomobject]@{Config='slow-pass';Eligible=$true;DiscordOK=4;AionTcpSuccessPct=100;AionTcpP95Ms=70},
    [pscustomobject]@{Config='fast-pass';Eligible=$true;DiscordOK=4;AionTcpSuccessPct=100;AionTcpP95Ms=30}
)
$rank = @(Get-AionRank -Rows $rows)
Assert-Equal 'fast-pass' $rank[0].Config 'rank eligibility before speed'
Assert-Equal 'slow-pass' $rank[1].Config 'rank second eligible'
Assert-Equal 'fast-fail' $rank[2].Config 'ineligible goes last'
# Property test: randomized IPv4 prefix equivalence vs explicit bitmask implementation.
$random = New-Object Random 20261119
for ($n=0; $n -lt 1000; $n++) {
    $a = [byte[]]@(0,0,0,0); $b = [byte[]]@(0,0,0,0)
    $random.NextBytes($a); $random.NextBytes($b)
    $prefix = $random.Next(0,33)
    $expected = $true
    for ($bit=0; $bit -lt $prefix; $bit++) {
        $idx = [int][math]::Floor($bit/8)
        $mask = 1 -shl (7 - ($bit % 8))
        if (($a[$idx] -band $mask) -ne ($b[$idx] -band $mask)) { $expected=$false; break }
    }
    $actual = Test-AionIPv4InCidr ($a -join '.') (($b -join '.') + '/' + $prefix)
    Assert-Equal $expected $actual "randomized CIDR iteration $n"
}
# Regression: standard ALT tests and default target list exist; new mode does not edit them.
Assert-True (Test-Path (Join-Path $root 'utils\test zapret.ps1')) 'original test still exists'
Assert-True (Test-Path (Join-Path $root 'utils\targets.txt')) 'original targets still exist'
$service = [IO.File]::ReadAllText((Join-Path $root 'service.bat'))
Assert-True ($service.Contains('if "%menu_choice%"=="12" goto run_tests')) 'original menu route remains'
Assert-True ($service.Contains('if "%menu_choice%"=="13" goto run_aion2_tests')) 'new menu route present'
Write-Host "PASS: $checks checks (including 1000 randomized CIDR properties)." -ForegroundColor Green
