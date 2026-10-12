$ErrorActionPreference = 'Stop'
if (!$env:GITHUB_ACTIONS) { throw 'This test runs only on a disposable CI runner.' }
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'utils\vpn-filter.ps1')

foreach ($entry in @(
    @('ipset-exclude-user.txt', '203.0.113.113/32'),
    @('list-general-user.txt', 'domain.example.abc'),
    @('list-exclude-user.txt', 'domain.example.abc')
)) {
    [IO.File]::WriteAllText((Join-Path $root ('lists\' + $entry[0])), $entry[1] + "`r`n")
}
if (!@(Get-NetAdapter -IncludeHidden | Where-Object HardwareInterface).Count) {
    $adapter = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
    if (!$adapter) { throw 'The runner has no usable network adapter.' }
    [IO.File]::WriteAllText((Join-Path $root 'utils\vpn-adapters.txt'), $adapter.Name)
}
$strategy = Join-Path $root 'general (ALT13 VPN).bat'
Invoke-VpnPreparation $strategy
$filterFile = Join-Path $root 'utils\vpn-filters\general (ALT13 VPN).filter.txt'
if (![IO.File]::ReadAllText($filterFile).Contains('ifIdx=')) { throw 'Native filter has no interface restriction.' }

$info = New-Object Diagnostics.ProcessStartInfo
$info.FileName = Join-Path $root 'bin\winws.exe'
$info.Arguments = (Get-StrategyArguments $strategy) + ' --wf-raw=false --debug=1'
$info.WorkingDirectory = Join-Path $root 'bin'
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$info.RedirectStandardOutput = $true
$info.RedirectStandardError = $true
$process = $null
try {
    $process = [Diagnostics.Process]::Start($info)
    $output = $process.StandardOutput.ReadToEndAsync()
    $errors = $process.StandardError.ReadToEndAsync()
    Start-Sleep -Seconds 4
    if ($process.HasExited) {
        throw "Native winws exited: $($process.ExitCode)`n$($output.Result)`n$($errors.Result)"
    }
    $process.Kill()
    $process.WaitForExit()
    $log = $output.Result + $errors.Result
    if (!$log.Contains('windivert initialized. capture is started.')) { throw "Driver did not initialize:`n$log" }
    Write-Host 'Native winws prepared the strategy filter and started WinDivert with a false filter. No traffic was intercepted.'
} finally {
    if ($process) {
        if (!$process.HasExited) { $process.Kill() }
        $process.Dispose()
    }
}
