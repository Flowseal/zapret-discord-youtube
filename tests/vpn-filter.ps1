$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$build = Join-Path $root ('build\vpn-tests-' + [Guid]::NewGuid().ToString('N'))
$fixture = Join-Path $build 'case with spaces (vpn)'
[IO.Directory]::CreateDirectory((Join-Path $fixture 'bin')) | Out-Null
[IO.Directory]::CreateDirectory((Join-Path $fixture 'utils')) | Out-Null
Copy-Item -LiteralPath (Join-Path $root 'bin\WinDivert.dll') -Destination (Join-Path $fixture 'bin\WinDivert.dll')
Copy-Item -LiteralPath (Join-Path $root 'general (ALT13 VPN).bat') -Destination $fixture
. (Join-Path $root 'utils\vpn-filter.ps1')

$script:count = 0
function Check {
    param([bool]$Condition, [string]$Message)
    if (!$Condition) { throw $Message }
    $script:count++
}
function Expect-Error {
    param([scriptblock]$Action, [string]$Message)
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    Check $failed $Message
}

$script:adapters = @(
    [pscustomobject]@{ Name = 'Ethernet'; HardwareInterface = $true; ifIndex = 8; Status = 'Up' },
    [pscustomobject]@{ Name = 'Wi-Fi'; HardwareInterface = $true; ifIndex = 12; Status = 'Disconnected' },
    [pscustomobject]@{ Name = 'arbitrary tunnel name'; HardwareInterface = $false; ifIndex = 5; Status = 'Up' }
)
function Get-NetAdapter {
    param([switch]$IncludeHidden)
    return $script:adapters
}
Check ((@(Get-VpnAdapterIndices $fixture) -join ',') -eq '8,12') 'Physical adapters must include disconnected Wi-Fi and exclude virtual tunnels.'
$script:adapters[2].ifIndex = 51
Check ((@(Get-VpnAdapterIndices $fixture) -join ',') -eq '8,12') 'A recreated VPN interface must not change the allowed adapters.'

$adapterFile = Join-Path $fixture 'utils\vpn-adapters.txt'
[IO.File]::WriteAllText($adapterFile, "# manual adapter`r`narbitrary tunnel name`r`n")
Check ((@(Get-VpnAdapterIndices $fixture) -join ',') -eq '51') 'An explicit virtual adapter must be supported for bridged networks.'
[IO.File]::WriteAllText($adapterFile, "missing adapter`r`n")
Expect-Error { Get-VpnAdapterIndices $fixture } 'Missing configured adapters must fail.'
[IO.File]::Delete($adapterFile)
$savedAdapters = $script:adapters
$script:adapters = @($script:adapters | Where-Object { !$_.HardwareInterface })
Expect-Error { Get-VpnAdapterIndices $fixture } 'An empty physical adapter list must fail.'
$script:adapters = $savedAdapters

function Get-Command {
    [CmdletBinding()]
    param([string]$Name)
    return $null
}
function Get-CimInstance {
    param([string]$ClassName)
    return @(
        [pscustomobject]@{ NetConnectionID = 'Ethernet'; PhysicalAdapter = $true; InterfaceIndex = 8 },
        [pscustomobject]@{ NetConnectionID = 'TAP'; PhysicalAdapter = $false; InterfaceIndex = 5 }
    )
}
Check ((@(Get-VpnAdapterIndices $fixture) -join ',') -eq '8') 'The CIM fallback must exclude non-physical adapters.'
[IO.File]::WriteAllText($adapterFile, "TAP`r`n")
Check ((@(Get-VpnAdapterIndices $fixture) -join ',') -eq '5') 'The CIM fallback must support an explicit adapter selection.'
[IO.File]::Delete($adapterFile)
Remove-Item Function:\Get-Command, Function:\Get-CimInstance

$strategy = Join-Path $fixture 'general (ALT13 VPN).bat'
foreach ($mode in @('disabled', 'all', 'tcp', 'udp')) {
    $gameFile = Join-Path $fixture 'utils\game_filter.enabled'
    if ($mode -eq 'disabled') {
        if ([IO.File]::Exists($gameFile)) { [IO.File]::Delete($gameFile) }
    } else {
        [IO.File]::WriteAllText($gameFile, $mode)
    }
    $arguments = Get-StrategyArguments $strategy
    $expectedTcp = if ($mode -in @('all', 'tcp')) { '1024-65535' } else { '12' }
    $expectedUdp = if ($mode -in @('all', 'udp')) { '1024-65535' } else { '12' }
    Check ($arguments.Contains("--wf-tcp=80,443,2053,2083,2087,2096,8443,$expectedTcp")) "Wrong TCP ports for $mode."
    Check ($arguments.Contains("--wf-udp=443,19294-19344,50000-50100,$expectedUdp")) "Wrong UDP ports for $mode."
    Check (!$arguments.Contains('--wf-raw') -and !$arguments.Contains('%')) 'Generated arguments must not reuse the previous raw filter or leave variables unexpanded.'
}
[IO.File]::WriteAllText($gameFile, '')
Check ((Get-StrategyArguments $strategy).Contains('--wf-udp=443,19294-19344,50000-50100,1024-65535')) 'An empty legacy Game Filter marker must follow service.bat behavior.'
foreach ($candidate in Get-ChildItem -LiteralPath $root -Filter 'general*.bat') {
    $arguments = Get-StrategyArguments $candidate.FullName
    Check ($arguments.Contains('--wf-tcp') -and !$arguments.Contains('%')) "Cannot read strategy arguments: $($candidate.Name)"
}
$originalArguments = Get-StrategyArguments (Join-Path $root 'general (ALT13).bat')
$vpnArguments = Get-StrategyArguments (Join-Path $root 'general (ALT13 VPN).bat')
Check ($originalArguments.Substring($originalArguments.IndexOf('--filter-udp=443')) -eq $vpnArguments.Substring($vpnArguments.IndexOf('--filter-udp=443'))) 'The original ALT13 DPI profiles must remain unchanged.'

$base = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'fixtures\alt13-all.filter.txt'))
$filter = New-VpnFilter $base @(12, 8, 12)
Check ($filter.EndsWith("and (ifIdx=8 or ifIdx=12)`r`n")) 'The interface restriction must use AND and deduplicate adapter indexes.'
Confirm-VpnFilter $filter (Join-Path $fixture 'bin\WinDivert.dll')
Check $true 'WinDivert rejected the generated filter.'
Expect-Error { New-VpnFilter '' @(8) } 'An empty base filter must fail.'
Expect-Error { New-VpnFilter $base @(0) } 'Invalid adapter indexes must fail.'
Expect-Error { Confirm-VpnFilter 'invalid filter !@' (Join-Path $fixture 'bin\WinDivert.dll') } 'Invalid raw filters must fail before replacing the saved filter.'

$stub = Join-Path $build 'winws-stub.exe'
Add-Type -OutputAssembly $stub -OutputType ConsoleApplication -TypeDefinition @'
using System;
using System.IO;
public static class WinwsStub {
    public static int Main(string[] args) {
        File.WriteAllLines(Environment.GetEnvironmentVariable("VPN_TEST_ARGUMENTS"), args);
        string fail = Environment.GetEnvironmentVariable("VPN_TEST_EXIT_CODE");
        if (!String.IsNullOrEmpty(fail)) return Int32.Parse(fail);
        foreach (string arg in args) {
            if (arg.StartsWith("--wf-save=")) {
                File.Copy(Environment.GetEnvironmentVariable("VPN_TEST_FILTER_SOURCE"), arg.Substring(10), true);
                return 0;
            }
        }
        return 1;
    }
}
'@
$env:VPN_TEST_ARGUMENTS = Join-Path $build 'arguments.txt'
$env:VPN_TEST_FILTER_SOURCE = Join-Path $PSScriptRoot 'fixtures\alt13-all.filter.txt'
try {
    Invoke-VpnPreparation $strategy $stub
    $destination = Join-Path $fixture 'utils\vpn-filters\general (ALT13 VPN).filter.txt'
    Check ([IO.File]::ReadAllText($destination) -eq $filter) 'The saved filter does not match the selected interfaces.'
    $nativeArguments = [IO.File]::ReadAllLines($env:VPN_TEST_ARGUMENTS)
    Check ($nativeArguments -contains "--ipset=$fixture\lists\ipset-exclude-user.txt") 'Quoted paths must survive the native argument boundary.'
    Check (@($nativeArguments | Where-Object { $_.StartsWith('--wf-save=') }).Count -eq 1) 'winws must only export its filter.'
    Check (!($nativeArguments -match '^--wf-raw')) 'The previous raw filter must not be sent to the constructor.'

    $old = [IO.File]::ReadAllText($destination)
    $env:VPN_TEST_EXIT_CODE = '1'
    Expect-Error { Invoke-VpnPreparation $strategy $stub } 'Native constructor errors must be propagated.'
    Check ([IO.File]::ReadAllText($destination) -eq $old) 'A failed preparation must preserve the existing filter.'
    Check (@(Get-ChildItem -LiteralPath (Split-Path $destination) -Filter '*.tmp').Count -eq 0) 'Temporary filters must be cleaned up.'
} finally {
    Remove-Item Env:\VPN_TEST_ARGUMENTS, Env:\VPN_TEST_FILTER_SOURCE, Env:\VPN_TEST_EXIT_CODE -ErrorAction SilentlyContinue
}

Write-Host "$script:count checks passed. No packet capture or service changes were performed."
