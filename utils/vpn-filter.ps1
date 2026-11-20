#requires -Version 3.0
param([string]$Strategy, [switch]$Elevate)

$ErrorActionPreference = 'Stop'

function Get-StrategyArguments {
    param([string]$Path)

    $root = Split-Path -Parent $Path
    $lines = [IO.File]::ReadAllLines($Path)
    $parts = @()
    $capture = $false
    foreach ($line in $lines) {
        if (!$capture) {
            if ($line -match '^\s*start\s+.*?"%BIN%winws\.exe"\s+(.*)$') {
                $line = $Matches[1]
                $capture = $true
            } else {
                continue
            }
        }
        $continued = $line.TrimEnd().EndsWith('^')
        $parts += $line.Trim().TrimEnd('^').TrimEnd()
        if (!$continued) { break }
    }
    if (!$parts.Count) { throw 'The strategy has no winws command.' }

    $mode = ''
    $gameFile = Join-Path $root 'utils\game_filter.enabled'
    $gameEnabled = Test-Path -LiteralPath $gameFile
    if ($gameEnabled) {
        $mode = [string](Get-Content -LiteralPath $gameFile | Where-Object { $_ -and !$_.StartsWith(';') } | Select-Object -First 1)
    }
    $tcp = if ($mode -in @('all', 'tcp')) { '1024-65535' } else { '12' }
    $udp = if ($gameEnabled -and $mode -ne 'tcp') { '1024-65535' } else { '12' }
    $game = if ($gameEnabled) { '1024-65535' } else { '12' }

    $arguments = $parts -join ' '
    $arguments = $arguments -replace '--wf-raw=(?:@"|"@)%~dp0utils\\vpn-filters\\[^"\r\n]+"', ''
    $arguments = $arguments.Replace('%BIN%', "$root\bin\").Replace('%LISTS%', "$root\lists\")
    $arguments = $arguments.Replace('%GameFilterTCP%', $tcp).Replace('%GameFilterUDP%', $udp).Replace('%GameFilter%', $game)
    if ($arguments -match '%[^%]+%') { throw 'The strategy contains an unsupported variable.' }
    if ($arguments -match '--wf-save(?:=|\s)') { throw 'The strategy already contains --wf-save.' }
    return $arguments.Trim()
}

function Get-VpnAdapterIndices {
    param([string]$Root)

    $names = @()
    $file = Join-Path $Root 'utils\vpn-adapters.txt'
    if (Test-Path -LiteralPath $file) {
        $names = @(Get-Content -LiteralPath $file | ForEach-Object { $_.Trim() } | Where-Object { $_ -and !$_.StartsWith('#') })
    }

    if (Get-Command Get-NetAdapter -ErrorAction SilentlyContinue) {
        $adapters = @(Get-NetAdapter -IncludeHidden)
        if ($names.Count) {
            $selected = @()
            foreach ($name in $names) {
                $match = @($adapters | Where-Object Name -eq $name)
                if (!$match.Count) { throw "Network adapter not found: $name" }
                $selected += $match
            }
        } else {
            $selected = @($adapters | Where-Object HardwareInterface)
        }
        $indices = @($selected | ForEach-Object { [int]$_.ifIndex } | Where-Object { $_ -gt 0 } | Sort-Object -Unique)
    } else {
        $adapters = @(Get-CimInstance Win32_NetworkAdapter)
        if ($names.Count) {
            $selected = @()
            foreach ($name in $names) {
                $match = @($adapters | Where-Object NetConnectionID -eq $name)
                if (!$match.Count) { throw "Network adapter not found: $name" }
                $selected += $match
            }
        } else {
            $selected = @($adapters | Where-Object PhysicalAdapter)
        }
        $indices = @($selected | ForEach-Object { [int]$_.InterfaceIndex } | Where-Object { $_ -gt 0 } | Sort-Object -Unique)
    }
    if (!$indices.Count) { throw 'No physical network adapters found. Specify the direct connection in utils\vpn-adapters.txt.' }
    return $indices
}

function New-VpnFilter {
    param([string]$BaseFilter, [int[]]$Indices)

    if ([string]::IsNullOrWhiteSpace($BaseFilter)) { throw 'winws returned an empty filter.' }
    if (!$Indices.Count -or @($Indices | Where-Object { $_ -le 0 }).Count) { throw 'Invalid network interface index.' }
    $interfaces = @($Indices | Sort-Object -Unique | ForEach-Object { "ifIdx=$_" }) -join ' or '
    return "($($BaseFilter.Trim())) and ($interfaces)`r`n"
}

function Confirm-VpnFilter {
    param([string]$Filter, [string]$Library)

    if (!('ZapretVpnFilter' -as [type])) {
        $dll = $Library.Replace('"', '""')
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class ZapretVpnFilter {
    [DllImport(@"$dll", CallingConvention = CallingConvention.Winapi)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool WinDivertHelperCompileFilter(string filter, int layer,
        IntPtr output, uint size, out IntPtr error, out uint position);
}
"@
    }
    $errorText = [IntPtr]::Zero
    $position = [uint32]0
    if (![ZapretVpnFilter]::WinDivertHelperCompileFilter($Filter, 0, [IntPtr]::Zero, 0, [ref]$errorText, [ref]$position)) {
        throw "Invalid WinDivert filter at $position`: $([Runtime.InteropServices.Marshal]::PtrToStringAnsi($errorText))"
    }
}

function Invoke-VpnPreparation {
    param([string]$Path, [string]$WinwsPath)

    $path = (Resolve-Path -LiteralPath $Path).Path
    $root = Split-Path -Parent $path
    $indices = @(Get-VpnAdapterIndices $root)
    $arguments = Get-StrategyArguments $path
    if (!$WinwsPath) { $WinwsPath = Join-Path $root 'bin\winws.exe' }
    $folder = Join-Path $root 'utils\vpn-filters'
    [IO.Directory]::CreateDirectory($folder) | Out-Null
    $name = [IO.Path]::GetFileNameWithoutExtension($path)
    $destination = Join-Path $folder "$name.filter.txt"
    $temporary = Join-Path $folder ([Guid]::NewGuid().ToString('N') + '.tmp')
    if ([Text.Encoding]::UTF8.GetByteCount($temporary) -ge 256) { throw 'The folder path is too long for winws. Use a shorter path.' }
    $process = $null
    try {
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = $WinwsPath
        $info.Arguments = $arguments + ' --wf-save="' + $temporary + '"'
        $info.WorkingDirectory = Join-Path $root 'bin'
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $process = [Diagnostics.Process]::Start($info)
        $output = $process.StandardOutput.ReadToEndAsync()
        $errors = $process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit(30000)) {
            $process.Kill()
            throw 'winws filter preparation timed out.'
        }
        if ($process.ExitCode -ne 0) { throw "winws could not prepare the filter: $($errors.Result.Trim())" }
        $filter = New-VpnFilter ([IO.File]::ReadAllText($temporary)) $indices
        Confirm-VpnFilter $filter (Join-Path $root 'bin\WinDivert.dll')
        [IO.File]::WriteAllText($temporary, $filter, [Text.Encoding]::ASCII)
        if ([IO.File]::Exists($destination)) {
            [IO.File]::Replace($temporary, $destination, $null)
        } else {
            [IO.File]::Move($temporary, $destination)
        }
        Write-Host "Direct network interfaces: $($indices -join ', ')"
    } finally {
        if ($process) { $process.Dispose() }
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

if ($MyInvocation.InvocationName -eq '.') { return }
try {
    if (!$Strategy) { throw 'Specify a strategy file.' }
    if ($Elevate) {
        Start-Process -FilePath $env:ComSpec -ArgumentList ('/c ""' + (Resolve-Path -LiteralPath $Strategy).Path + '""') -Verb RunAs
    } else {
        Invoke-VpnPreparation $Strategy
    }
} catch {
    Write-Host "VPN strategy: $($_.Exception.Message)"
    exit 1
}
