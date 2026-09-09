param(
    [string]$CurrentVersion,
    [string]$InstallDir,
    [string]$RestartBatch,
    [switch]$Quiet,
    [switch]$Install,
    [switch]$OpenReleasePage,
    [switch]$Apply,
    [string]$PackagePath,
    [string]$ExpectedHash,
    [string]$ReleaseVersion,
    [int]$ParentProcessId,
    [switch]$SkipRuntimeControl,
    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$LogPath = Join-Path $env:TEMP 'zapret-discord-youtube-update.log'

function Write-Log([string]$Message) {
    try { Add-Content -LiteralPath $LogPath -Value ('{0:u} {1}' -f (Get-Date), $Message) -Encoding UTF8 } catch { }
}

function Show-UpdateMessage([string]$Message, [string]$Icon) {
    Write-Log $Message
    Write-Host $Message
    if (-not $NonInteractive) {
        try {
            Add-Type -AssemblyName PresentationFramework
            [System.Windows.MessageBox]::Show($Message, 'Zapret update', 'OK', $Icon) | Out-Null
        } catch { }
    }
}

function Get-NormalizedVersion([string]$Version) {
    return $Version.Trim().TrimStart([char[]]'vV')
}

function Test-IsNewerVersion([string]$Remote, [string]$Local) {
    $pattern = '^(\d+)\.(\d+)\.(\d+)([a-z]?)$'
    $remoteMatch = [regex]::Match((Get-NormalizedVersion $Remote), $pattern, 'IgnoreCase')
    $localMatch = [regex]::Match((Get-NormalizedVersion $Local), $pattern, 'IgnoreCase')
    if (-not $remoteMatch.Success -or -not $localMatch.Success) {
        throw "Unsupported release version. Local: '$Local', remote: '$Remote'."
    }
    for ($index = 1; $index -le 3; $index++) {
        $remotePart = [int]$remoteMatch.Groups[$index].Value
        $localPart = [int]$localMatch.Groups[$index].Value
        if ($remotePart -ne $localPart) { return $remotePart -gt $localPart }
    }
    return [string]::Compare($remoteMatch.Groups[4].Value, $localMatch.Groups[4].Value, [StringComparison]::OrdinalIgnoreCase) -gt 0
}

function Quote-ProcessArgument([string]$Value) {
    # Windows command-line parsing doubles backslashes before quotes and the closing quote.
    return '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}

function Get-AssetHash($Asset) {
    $digest = [string]$Asset.digest
    if (-not $digest) { return $null }
    if ($digest -notmatch '^sha256:([0-9a-fA-F]{64})$') { throw 'Invalid GitHub asset SHA-256 digest.' }
    return $Matches[1]
}

function Get-LocalService([string]$Executable) {
    $service = Get-CimInstance Win32_Service -Filter "Name = 'zapret'"
    if ($service) {
        $match = [regex]::Match($service.PathName, '^\s*(?:"([^"]+)"|(\S+))(?=\s|$)')
        $path = if ($match.Groups[1].Success) { $match.Groups[1].Value } else { $match.Groups[2].Value }
        if (-not $match.Success -or $path -notmatch '^(?:[a-zA-Z]:\\|\\\\)' -or [IO.Path]::GetFullPath($path) -ine $Executable) {
            throw 'The zapret service belongs to another installation or its PathName is ambiguous. It was not touched.'
        }
    }
    return $service
}

function Get-StrategyCommand([string]$BatchPath, [string]$Root) {
    # Read the shipped BAT format without executing a strategy during preparation.
    $text = [regex]::Replace([IO.File]::ReadAllText($BatchPath), '\^\r?\n\s*', ' ')
    $commands = [regex]::Matches($text, '(?im)^\s*start\s+[^\r\n]*?"%BIN%winws\.exe"\s+([^\r\n]+)')
    if ($commands.Count -ne 1) { throw "Unsupported strategy format: $BatchPath" }
    $values = @{ BIN = "$Root\bin\"; LISTS = "$Root\lists\"; GameFilter = '12'; GameFilterTCP = '12'; GameFilterUDP = '12' }
    $flag = Join-Path $Root 'utils\game_filter.enabled'
    if (Test-Path -LiteralPath $flag) {
        $mode = @(Get-Content -LiteralPath $flag | Where-Object { $_ }) | Select-Object -First 1
        $values.GameFilter = '1024-65535'
        $values.GameFilterTCP = if ($mode -in @('all','tcp')) { '1024-65535' } else { '12' }
        $values.GameFilterUDP = if ($mode -eq 'tcp') { '12' } else { '1024-65535' }
    }
    $arguments = $commands[0].Groups[1].Value.Replace('^!', '!')
    # Validate BAT syntax before inserting paths, which may legitimately contain & or %.
    $unquoted = [regex]::Replace($arguments, '"[^"]*"', '')
    if ($unquoted -match '[&|<>^\r\n]' -or ($arguments.ToCharArray() | Where-Object { $_ -eq '"' }).Count % 2) {
        throw "Unsupported strategy arguments: $BatchPath"
    }
    $arguments = [regex]::Replace($arguments, '%~dp0|%([^%]+)%', {
        param($match)
        if ($match.Value -eq '%~dp0') { return "$Root\" }
        if (-not $values.ContainsKey($match.Groups[1].Value)) { throw "Unsupported strategy variable: $($match.Value)" }
        return $values[$match.Groups[1].Value]
    })
    return (Quote-ProcessArgument (Join-Path $Root 'bin\winws.exe')) + ' ' + $arguments.Trim()
}

function Get-CommandKey([string]$CommandLine) {
    # Ignore spacing between arguments and equivalent placement of quotes.
    return (@([regex]::Matches($CommandLine, '(?:[^\s"]+|"[^"]*")+') | ForEach-Object { $_.Value.Replace('"', '') }) -join "`n")
}

function Get-UpdatedCommand([string]$Name, [string]$PackageRoot, [string]$Root) {
    if ($Name -ne [IO.Path]::GetFileName($Name) -or [IO.Path]::GetExtension($Name) -ine '.bat') { throw 'Invalid strategy filename.' }
    $batch = Join-Path $PackageRoot $Name
    if (-not (Test-Path -LiteralPath $batch -PathType Leaf)) { throw "Selected strategy is missing from release: $Name" }
    return Get-StrategyCommand $batch $Root
}

function Get-ProcessUpdateCommand([string]$CommandLine, [string]$PackageRoot, [string]$Root) {
    $key = Get-CommandKey $CommandLine
    $candidates = @(Get-ChildItem -LiteralPath $Root -Filter 'general*.bat' -File | Where-Object {
        try { (Get-CommandKey (Get-StrategyCommand $_.FullName $Root)) -ceq $key } catch { $false }
    })
    if (-not $candidates.Count) { throw 'Cannot identify the running strategy. Stop it and start the desired BAT before updating.' }
    $commands = @($candidates | ForEach-Object { Get-UpdatedCommand $_.Name $PackageRoot $Root })
    $keys = @($commands | ForEach-Object { Get-CommandKey $_ } | Select-Object -Unique)
    if ($keys.Count -ne 1) { throw 'Running strategy matches multiple BAT files with different release parameters. Stop it and update from the desired BAT.' }
    return $commands[0]
}

function Set-ServiceCommand($Service, [string]$CommandLine) {
    $result = Invoke-CimMethod -InputObject $Service -MethodName Change -Arguments @{ PathName = $CommandLine }
    if ($result.ReturnValue -ne 0) { throw "Cannot update service arguments: $($result.ReturnValue)" }
}

function Invoke-ApplyUpdate {
    $root = [IO.Path]::GetFullPath($InstallDir).TrimEnd('\')
    $executable = Join-Path $root 'bin\winws.exe'
    $backup = $root + '.backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N')
    $extractRoot = Join-Path $env:TEMP ('zapret-extract-' + [Guid]::NewGuid().ToString('N'))
    $changed = @()
    $serviceStopped = $false
    $stoppedProcesses = @()
    $service = $null
    $serviceCommandChanged = $false
    $installed = $false
    $canRestart = $false
    $failure = $null
    $mutex = New-Object Threading.Mutex($false, 'Global\ZapretDiscordYoutubeUpdate')
    $locked = $false
    try {
        $locked = $mutex.WaitOne(0)
        if (-not $locked) { throw 'Another update is already running.' }
        if ($ParentProcessId) {
            # The checking PowerShell must exit first; give its BAT caller time to take exit 20.
            $parent = Get-Process -Id $ParentProcessId -ErrorAction SilentlyContinue
            if ($parent -and -not $parent.WaitForExit(60000)) { throw 'The update-check parent did not exit.' }
            Start-Sleep -Seconds 2
        }
        $canRestart = $true
        if (-not (Test-Path -LiteralPath (Join-Path $root 'service.bat') -PathType Leaf)) { throw 'Invalid installation directory.' }
        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        New-Item -ItemType Directory -Path $extractRoot | Out-Null
        $stream = [IO.File]::Open($PackagePath, 'Open', 'Read', 'None')
        $sha256 = [Security.Cryptography.SHA256]::Create()
        try {
            $hash = [BitConverter]::ToString($sha256.ComputeHash($stream)).Replace('-', '')
            if ($ExpectedHash -notmatch '^[0-9a-fA-F]{64}$' -or $hash -ne $ExpectedHash) { throw 'Package checksum mismatch.' }
            $stream.Position = 0
            $archive = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Read, $true)
            try {
                foreach ($entry in $archive.Entries) {
                    $name = $entry.FullName.Replace('/', '\')
                    $parts = $name.TrimEnd('\').Split('\')
                    if ([IO.Path]::IsPathRooted($name) -or $name.Contains(':') -or
                        (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) { throw "Unsafe ZIP path: $name" }
                    foreach ($part in $parts) {
                        if (-not $part -or $part -match '[<>"|?*\x00-\x1f]' -or $part -match '[. ]$' -or
                            $part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') { throw "Unsafe ZIP path: $name" }
                    }
                    $destination = [IO.Path]::GetFullPath((Join-Path $extractRoot $name))
                    if (-not $destination.StartsWith($extractRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe ZIP path: $name" }
                    if ($name.EndsWith('\')) {
                        New-Item -ItemType Directory -Path $destination -Force | Out-Null
                    } else {
                        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
                        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $destination, $false)
                    }
                }
            } finally { $archive.Dispose() }
        } finally { $sha256.Dispose(); $stream.Dispose() }
        $top = @(Get-ChildItem -LiteralPath $extractRoot -Force)
        if ($top.Count -ne 1 -or -not $top[0].PSIsContainer) { throw 'Expected one top-level release directory.' }
        $packageRoot = $top[0].FullName
        foreach ($required in @('service.bat', 'general.bat', 'bin\winws.exe', 'utils\update.ps1')) {
            if (-not (Test-Path -LiteralPath (Join-Path $packageRoot $required) -PathType Leaf)) { throw "Missing release file: $required" }
        }
        $versionMatch = [regex]::Match((Get-Content -LiteralPath (Join-Path $packageRoot 'service.bat') -Raw), '(?im)^set "LOCAL_VERSION=([^"\r\n]+)"\r?$')
        if (-not $versionMatch.Success -or (Get-NormalizedVersion $versionMatch.Groups[1].Value) -ne (Get-NormalizedVersion $ReleaseVersion)) {
            throw 'Release version does not match the service.bat constant.'
        }
        $preserved = @(
            'lists\ipset-exclude-user.txt', 'lists\list-general-user.txt', 'lists\list-exclude-user.txt',
            'lists\ipset-all.txt', 'lists\ipset-all.txt.backup', 'utils\targets.txt',
            'bin\ACTIVE_DISCORD_UDP.bin', 'bin\ACTIVE_GAME_UDP.bin', 'ipset_switched.flag'
        )
        $markers = @('utils\game_filter.enabled', 'utils\check_updates.enabled', 'utils\auto_update.enabled')
        $files = @(Get-ChildItem -LiteralPath $packageRoot -Recurse -File -Force | Sort-Object FullName | ForEach-Object {
            $relative = $_.FullName.Substring($packageRoot.Length + 1)
            $target = Join-Path $root $relative
            if ($relative -in $markers -or ($relative -in $preserved -and (Test-Path -LiteralPath $target))) { return }
            # Reject junctions/symlinks in destination ancestry before copying anything.
            $ancestor = $target
            while ($ancestor) {
                if (Test-Path -LiteralPath $ancestor) {
                    $item = Get-Item -LiteralPath $ancestor -Force
                    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse point in destination: $ancestor" }
                }
                $ancestor = Split-Path -Parent $ancestor
            }
            if (Test-Path -LiteralPath $target -PathType Container) { throw "Directory conflicts with release file: $relative" }
            [pscustomobject]@{ Source = $_.FullName; Relative = $relative; Target = $target; Existed = (Test-Path -LiteralPath $target) }
        })
        # Finish every backup before stopping runtime or overwriting installation files.
        New-Item -ItemType Directory -Path $backup | Out-Null
        foreach ($file in $files) {
            if ($file.Existed) {
                $saved = Join-Path $backup $file.Relative
                New-Item -ItemType Directory -Path (Split-Path -Parent $saved) -Force | Out-Null
                Copy-Item -LiteralPath $file.Target -Destination $saved -Force
            }
        }
        if (-not $SkipRuntimeControl) {
            $service = Get-LocalService $executable
            if ($service) {
                $originalServiceCommand = $service.PathName
                $strategy = Get-ItemPropertyValue -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\zapret' -Name 'zapret-discord-youtube'
                $updatedServiceCommand = Get-UpdatedCommand ($strategy + '.bat') $packageRoot $root
            }
            # Resolve all strategies before stopping anything; never silently reuse stale arguments.
            $processPlans = @(Get-CimInstance Win32_Process -Filter "Name = 'winws.exe'" | Where-Object {
                $_.ExecutablePath -and [IO.Path]::GetFullPath($_.ExecutablePath) -ieq $executable -and
                (-not $service -or $_.ProcessId -ne $service.ProcessId)
            } | ForEach-Object {
                if (-not $_.CommandLine) { throw 'Cannot save local winws command line for restart.' }
                [pscustomobject]@{ Process = $_; Original = $_.CommandLine; Updated = (Get-ProcessUpdateCommand $_.CommandLine $packageRoot $root) }
            })
            if ($service -and $service.State -ne 'Stopped') {
                # Remember intent before Stop-Service: a timeout may still have stopped it.
                $serviceStopped = $true
                Stop-Service -Name 'zapret'
                (Get-Service -Name 'zapret').WaitForStatus('Stopped', [TimeSpan]::FromSeconds(15))
            }
            foreach ($plan in $processPlans) {
                $process = $plan.Process
                if ($process.ExecutablePath -and [IO.Path]::GetFullPath($process.ExecutablePath) -ieq $executable) {
                    if (-not $process.CommandLine) { throw 'Cannot save local winws command line for restart.' }
                    $localProcess = Get-Process -Id $process.ProcessId
                    if (-not $localProcess.Path -or [IO.Path]::GetFullPath($localProcess.Path) -ine $executable) { throw 'Local winws changed before stop.' }
                    Stop-Process -InputObject $localProcess -Force
                    $stoppedProcesses += $plan
                    if (-not $localProcess.WaitForExit(15000)) { throw 'Local winws did not exit.' }
                }
            }
        }
        foreach ($file in $files) {
            $changed += $file
            New-Item -ItemType Directory -Path (Split-Path -Parent $file.Target) -Force | Out-Null
            Copy-Item -LiteralPath $file.Source -Destination $file.Target -Force
        }
        if (-not $SkipRuntimeControl -and $service) {
            $serviceCommandChanged = $true
            Set-ServiceCommand $service $updatedServiceCommand
        }
        $installed = $true
    } catch {
        $failure = $_.Exception.Message
        Write-Log "Update failed: $failure"
        $rollbackErrors = @()
        foreach ($file in $changed) {
            try {
                if ($file.Existed) { Copy-Item -LiteralPath (Join-Path $backup $file.Relative) -Destination $file.Target -Force }
                elseif (Test-Path -LiteralPath $file.Target -PathType Leaf) { Remove-Item -LiteralPath $file.Target -Force }
            } catch {
                $restoreError = $_.Exception.Message
                # A sharing violation may prevent both writes while leaving the old file intact.
                # Keep attempted writes in $changed: Copy-Item can also fail after a partial write.
                $unchanged = $false
                if ($file.Existed) {
                    try {
                        $savedHash = (Get-FileHash -LiteralPath (Join-Path $backup $file.Relative) -Algorithm SHA256).Hash
                        $unchanged = $savedHash -eq (Get-FileHash -LiteralPath $file.Target -Algorithm SHA256).Hash
                    } catch { }
                }
                if (-not $unchanged) { $rollbackErrors += $restoreError }
            }
        }
        if ($serviceCommandChanged) {
            try { Set-ServiceCommand (Get-LocalService $executable) $originalServiceCommand }
            catch { $rollbackErrors += $_.Exception.Message }
        }
        if ($rollbackErrors.Count) {
            $canRestart = $false
            $failure += "`nRollback incomplete: " + ($rollbackErrors -join '; ')
        } elseif ($changed.Count) { $failure += "`nChanged files restored from backup." }
        else { $failure += "`nInstallation files were not changed." }
    } finally {
        if ($locked) {
            if (-not $SkipRuntimeControl -and $canRestart) {
                try {
                    $restartService = Get-LocalService $executable
                    if ($serviceStopped) {
                        if (-not $restartService) { throw 'The local service no longer exists.' }
                        Start-Service -Name 'zapret'
                    }
                    foreach ($plan in $stoppedProcesses) {
                        $commandLine = if ($installed) { $plan.Updated } else { $plan.Original }
                        $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $commandLine; CurrentDirectory = $root }
                        if ($result.ReturnValue -ne 0) { throw "winws restart failed: $($result.ReturnValue)" }
                    }
                    if ($RestartBatch -and -not $serviceStopped -and -not $stoppedProcesses.Count -and
                        (-not $restartService -or $restartService.State -eq 'Stopped')) {
                        $batchPath = Join-Path $root ([IO.Path]::GetFileName($RestartBatch))
                        if (-not (Test-Path -LiteralPath $batchPath -PathType Leaf)) { throw "Restart BAT not found: $batchPath" }
                        $previousNoUpdateCheck = $env:NO_UPDATE_CHECK
                        $env:NO_UPDATE_CHECK = '1'
                        try { Start-Process -FilePath 'cmd.exe' -ArgumentList ('/d /c ""{0}""' -f $batchPath) -WorkingDirectory $root -WindowStyle Hidden | Out-Null }
                        finally { $env:NO_UPDATE_CHECK = $previousNoUpdateCheck }
                    }
                } catch { $failure += "`nRuntime restart failed: $($_.Exception.Message)" }
            }
            $mutex.ReleaseMutex()
        }
        $mutex.Dispose()
        Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($failure) {
        $status = if ($installed) { "Update $ReleaseVersion installed, but runtime restart failed." } else { 'Update was not installed.' }
        Show-UpdateMessage "$status`n$failure`nBackup (if created): $backup`nLog (best effort): $LogPath" 'Error'
        exit 1
    }
    Show-UpdateMessage "Update $ReleaseVersion installed. Runtime start requested where applicable; connectivity was not tested.`nBackup of replaced files: $backup" 'Information'
    exit 0
}

try {
    if ($OpenReleasePage -and ($Install -or $Apply)) { throw 'OpenReleasePage cannot be combined with Install or Apply.' }
    if ($Apply) { Invoke-ApplyUpdate }
    if (-not $CurrentVersion -or -not $InstallDir) { throw 'CurrentVersion and InstallDir are required.' }
    $headers = @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'zapret-discord-youtube-updater'; 'X-GitHub-Api-Version' = '2022-11-28' }
    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/Flowseal/zapret-discord-youtube/releases/latest' -Headers $headers -TimeoutSec 10
    $remoteVersion = Get-NormalizedVersion $release.tag_name
    if (-not (Test-IsNewerVersion $remoteVersion $CurrentVersion)) {
        if (-not $Quiet) { Write-Host "Latest version installed: $CurrentVersion" }
        exit 0
    }
    Write-Host "New version available: $remoteVersion (installed: $CurrentVersion)"
    if (-not $Install) {
        $releaseUrl = 'https://github.com/Flowseal/zapret-discord-youtube/releases/tag/' + [Uri]::EscapeDataString($release.tag_name)
        Start-Process -FilePath $releaseUrl | Out-Null
        exit 0
    }
    $assetName = "zapret-discord-youtube-$remoteVersion.zip"
    $packageAsset = @($release.assets | Where-Object { $_.name -eq $assetName })
    $checksumAsset = @($release.assets | Where-Object { $_.name -eq "$assetName.sha256" })
    if ($packageAsset.Count -ne 1 -or $checksumAsset.Count -gt 1) { throw "Release $remoteVersion has missing or ambiguous ZIP/checksum assets." }
    $expectedPackageHash = Get-AssetHash $packageAsset[0]
    if (-not $expectedPackageHash -and $checksumAsset.Count -ne 1) { throw "Release $remoteVersion has neither a GitHub SHA-256 digest nor a .zip.sha256 file." }
    if ($NonInteractive) { throw 'Install requires interactive confirmation. Run without -NonInteractive.' }
    if ((Read-Host 'Download and install it now? [Y/N]') -notmatch '^(?i:y|yes)$') { Write-Host 'Update skipped.'; exit 0 }
    $workDir = Join-Path $env:TEMP ('zapret-update-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $workDir | Out-Null
    $downloadedPackage = Join-Path $workDir $assetName
    $downloadedChecksum = Join-Path $workDir "$assetName.sha256"
    $temporaryUpdater = Join-Path $workDir 'update.ps1'
    Write-Host 'Downloading update...'
    Invoke-WebRequest -Uri $packageAsset[0].browser_download_url -Headers $headers -OutFile $downloadedPackage -UseBasicParsing -TimeoutSec 120
    if ($checksumAsset.Count -eq 1) {
        Invoke-WebRequest -Uri $checksumAsset[0].browser_download_url -Headers $headers -OutFile $downloadedChecksum -UseBasicParsing -TimeoutSec 30
        $checksumMatch = [regex]::Match((Get-Content -LiteralPath $downloadedChecksum -Raw), '^\s*([0-9a-fA-F]{64})(?:\s+\*?[^\r\n]+)?\s*$')
        if (-not $checksumMatch.Success) { throw 'Invalid release checksum file.' }
        if ($expectedPackageHash -and $expectedPackageHash -ne $checksumMatch.Groups[1].Value) { throw 'GitHub digest and checksum file disagree.' }
        $expectedPackageHash = $checksumMatch.Groups[1].Value
    }
    if ((Get-FileHash -LiteralPath $downloadedPackage -Algorithm SHA256).Hash -ne $expectedPackageHash) { throw 'Downloaded package checksum mismatch.' }
    Copy-Item -LiteralPath $PSCommandPath -Destination $temporaryUpdater
    $argumentList = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Quote-ProcessArgument $temporaryUpdater), '-Apply',
        '-InstallDir', (Quote-ProcessArgument ([IO.Path]::GetFullPath($InstallDir).TrimEnd('\'))),
        '-PackagePath', (Quote-ProcessArgument $downloadedPackage), '-ExpectedHash', $expectedPackageHash,
        '-ReleaseVersion', (Quote-ProcessArgument $remoteVersion), '-ParentProcessId', $PID
    )
    if ($RestartBatch) { $argumentList += @('-RestartBatch', (Quote-ProcessArgument ([IO.Path]::GetFileName($RestartBatch)))) }
    Write-Host 'Administrator permission is required to install the update.'
    Start-Process -FilePath 'powershell.exe' -ArgumentList ($argumentList -join ' ') -Verb RunAs -WorkingDirectory $workDir -WindowStyle Hidden | Out-Null
    exit 20
} catch {
    Write-Log ('Update failed: ' + $_.Exception.Message)
    Write-Warning "Update was not installed: $($_.Exception.Message)"
    exit 1
}
