$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$processes = @()
function Wait-InstallerMarker {
    param([Diagnostics.Process]$Process, [string]$Path)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while (![IO.File]::Exists($Path)) {
        if ($Process.HasExited -or $timer.ElapsedMilliseconds -gt 45000) {
            throw "Installer did not reach $Path"
        }
        Start-Sleep -Milliseconds 25
    }
}
function Invoke-TestInstaller {
    param([Diagnostics.ProcessStartInfo]$Info)
    $menuMarker = Join-Path $Info.WorkingDirectory 'test-menu-ready.txt'
    $choiceMarker = Join-Path $Info.WorkingDirectory 'test-choice-ready.txt'
    [IO.File]::Delete($menuMarker)
    [IO.File]::Delete($choiceMarker)
    $process = [Diagnostics.Process]::Start($Info)
    $script:processes += $process
    $output = $process.StandardOutput.ReadToEndAsync()
    $errors = $process.StandardError.ReadToEndAsync()
    try {
    Wait-InstallerMarker $process $menuMarker
    $process.StandardInput.WriteLine('1')
    $process.StandardInput.Flush()
    Wait-InstallerMarker $process $choiceMarker
    [IO.File]::Delete($menuMarker)
    $process.StandardInput.WriteLine('1')
    $process.StandardInput.Flush()
    Wait-InstallerMarker $process $menuMarker
    $process.StandardInput.WriteLine('0')
    $process.StandardInput.Flush()
    if (!$process.WaitForExit(10000)) { throw 'Installer did not exit from the menu.' }
    return $output.Result + $errors.Result
    } catch {
        if (!$process.HasExited) { $process.Kill() }
        $process.WaitForExit()
        Write-Host ($output.Result + $errors.Result)
        throw
    }
}
$fixture = Join-Path $root ('build\vpn-service-' + [Guid]::NewGuid().ToString('N') + '\folder with spaces (test)')
foreach ($folder in @($fixture, "$fixture\bin", "$fixture\utils", "$fixture\lists")) {
    [IO.Directory]::CreateDirectory($folder) | Out-Null
}
Copy-Item -LiteralPath "$root\service.bat", "$root\general (ALT13 VPN).bat" -Destination $fixture
$servicePath = Join-Path $fixture 'service.bat'
$serviceText = [IO.File]::ReadAllText($servicePath) -replace '\r?\n', "`r`n"
$menuBoundary = "`r`n:menu`r`n" + 'echo ready>"%~dp0test-menu-ready.txt"' + "`r`n"
$serviceText = $serviceText.Replace("`r`n:menu`r`n", $menuBoundary)
$serviceText = $serviceText.Replace(':: Choosing file', 'echo ready>"%~dp0test-choice-ready.txt"' + "`r`n:: Choosing file")
$serviceText = $serviceText -replace '(?m)^([ \t]*)pause[ \t]*\r?$', '$1rem test pause'
[IO.File]::WriteAllText($servicePath, $serviceText, (New-Object Text.UTF8Encoding($false)))
Copy-Item -LiteralPath "$root\utils\vpn-filter.ps1" -Destination "$fixture\utils"
$helperPath = Join-Path $fixture 'utils\vpn-filter.ps1'
$helperText = [IO.File]::ReadAllText($helperPath)
$entryPoint = 'if ($MyInvocation.InvocationName -eq ''.'') { return }'
$adapterStub = 'function Get-VpnAdapterIndices { param([string]$Root) return @(8,12) }' + "`r`n" + $entryPoint
$helperText = $helperText.Replace($entryPoint, $adapterStub)
[IO.File]::WriteAllText($helperPath, $helperText, (New-Object Text.UTF8Encoding($false)))
Copy-Item -LiteralPath "$root\bin\WinDivert.dll" -Destination "$fixture\bin"
$mock = Join-Path $fixture 'mock.exe'
Add-Type -OutputAssembly $mock -OutputType ConsoleApplication -TypeDefinition @'
using System;
using System.IO;
using System.Reflection;
public static class SystemStub {
    public static int Main(string[] args) {
        string tool = Path.GetFileNameWithoutExtension(Assembly.GetEntryAssembly().Location).ToLowerInvariant();
        string log = Environment.GetEnvironmentVariable("VPN_SERVICE_TEST_LOG");
        File.AppendAllText(log, tool + "\t" + String.Join("\t", args) + "\n");
        if (tool == "winws") {
            File.WriteAllLines(Environment.GetEnvironmentVariable("VPN_SERVICE_TEST_ARGUMENTS"), args);
            if (Environment.GetEnvironmentVariable("VPN_SERVICE_TEST_FAIL") == "1") return 1;
            foreach (string arg in args) {
                if (arg.StartsWith("--wf-save=")) {
                    File.Copy(Environment.GetEnvironmentVariable("VPN_SERVICE_TEST_FILTER"), arg.Substring(10), true);
                    return 0;
                }
            }
            return 1;
        }
        if (tool == "sc" && args.Length > 0 && args[0] == "query") return 1060;
        if (tool == "reg" && args.Length > 0 && args[0] == "query") return 1;
        if (tool == "netsh") Console.WriteLine("timestamps enabled");
        return 0;
    }
}
'@
foreach ($tool in @('sc', 'net', 'reg', 'netsh', 'taskkill')) {
    Copy-Item -LiteralPath $mock -Destination "$fixture\$tool.exe"
}
Copy-Item -LiteralPath $mock -Destination "$fixture\bin\winws.exe"

$logPath = Join-Path $fixture 'system-calls.txt'
$argumentsPath = Join-Path $fixture 'native-arguments.txt'
try {
$info = New-Object Diagnostics.ProcessStartInfo
$info.FileName = $env:ComSpec
$info.Arguments = '/d /c service.bat admin'
$info.WorkingDirectory = $fixture
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$info.RedirectStandardInput = $true
$info.RedirectStandardOutput = $true
$info.RedirectStandardError = $true
$info.EnvironmentVariables['PATH'] = "$fixture;$env:PATH"
$info.EnvironmentVariables['VPN_SERVICE_TEST_LOG'] = $logPath
$info.EnvironmentVariables['VPN_SERVICE_TEST_ARGUMENTS'] = $argumentsPath
$info.EnvironmentVariables['VPN_SERVICE_TEST_FILTER'] = "$PSScriptRoot\fixtures\alt13-all.filter.txt"
$installerInfo = $info
[IO.File]::WriteAllText("$fixture\output.txt", (Invoke-TestInstaller $installerInfo))
$calls = [IO.File]::ReadAllLines($logPath)
$create = @($calls | Where-Object { $_.StartsWith("sc`tcreate`t") })
if ($create.Count -ne 1) { throw "Expected one mocked service creation. See $fixture\output.txt" }
$fields = $create[0].Split("`t")
$binPath = $fields[[Array]::IndexOf($fields, 'binPath=') + 1]
if ($binPath -notmatch '^"([^"\r\n]+)"\s+(.+)$') { throw "Invalid service command: $binPath" }
$executable = $Matches[1]
$arguments = $Matches[2]

$info = New-Object Diagnostics.ProcessStartInfo
$info.FileName = $executable
$info.Arguments = $arguments + ' --wf-save="' + "$fixture\roundtrip.filter.txt" + '"'
$info.WorkingDirectory = "$fixture\bin"
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$info.EnvironmentVariables['VPN_SERVICE_TEST_LOG'] = $logPath
$info.EnvironmentVariables['VPN_SERVICE_TEST_ARGUMENTS'] = $argumentsPath
$info.EnvironmentVariables['VPN_SERVICE_TEST_FILTER'] = "$PSScriptRoot\fixtures\alt13-all.filter.txt"
$process = [Diagnostics.Process]::Start($info)
$processes += $process
$process.WaitForExit()
$native = [IO.File]::ReadAllLines($argumentsPath)
if ($native -contains 'tasklist' -or $native -contains 'pause' -or $native -contains 'call') {
    throw 'Startup commands were included in the service arguments.'
}
$rawPosition = [Array]::IndexOf($native, '--wf-raw')
if ($rawPosition -lt 0 -or $native[$rawPosition + 1] -ne "@$fixture\utils\vpn-filters\general (ALT13 VPN).filter.txt") {
    throw 'The raw filter path did not survive service installation.'
}
$ipsetPosition = [Array]::IndexOf($native, '--ipset')
if ($ipsetPosition -lt 0 -or $native[$ipsetPosition + 1] -ne "$fixture\lists\ipset-exclude-user.txt") {
    throw 'The global IP exclusion did not survive service installation.'
}
if ($native -contains '--wf-save' -or @($native | Where-Object { $_.StartsWith('--wf-save=') }).Count -ne 1) {
    throw 'The temporary constructor flag leaked into service arguments.'
}
if (@($calls | Where-Object { $_.StartsWith("winws`t") }).Count -ne 1) {
    throw 'Filter preparation did not happen before service creation.'
}
if ([Array]::IndexOf($calls, ($calls | Where-Object { $_.StartsWith("winws`t") } | Select-Object -First 1)) -gt [Array]::IndexOf($calls, $create[0])) {
    throw 'The service was changed before filter preparation.'
}
Write-Host 'Service menu and quoted native arguments passed. All service, registry and TCP commands were mocked.'

$failureLog = Join-Path $fixture 'failure-calls.txt'
$installerInfo.EnvironmentVariables['VPN_SERVICE_TEST_LOG'] = $failureLog
$installerInfo.EnvironmentVariables['VPN_SERVICE_TEST_FAIL'] = '1'
[IO.File]::WriteAllText("$fixture\failure-output.txt", (Invoke-TestInstaller $installerInfo))
$calls = [IO.File]::ReadAllLines($failureLog)
if ($calls -match '^(sc\t(create|delete|start)|net\tstop|reg\tadd)\t') {
    throw 'The installer changed a service after filter preparation failed.'
}
Write-Host 'Preparation failure left service and registry operations untouched.'
} finally {
    foreach ($owned in $processes) {
        if (!$owned.HasExited) { $owned.Kill() }
        $owned.Dispose()
    }
}
