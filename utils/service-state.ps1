param(
    [Parameter(Position = 0)]
    [string]$CommandName,

    [Parameter(Position = 1)]
    [string]$RootPath,

    [Parameter(Position = 2)]
    [string]$Argument1,

    [Parameter(Position = 3)]
    [string]$Argument2
)

Set-StrictMode -Version 2
$ErrorActionPreference = "Stop"

if ($RootPath) {
    $trimmedRootPath = $RootPath.Trim()
    if ($trimmedRootPath.Length -ge 2 -and $trimmedRootPath.StartsWith('"') -and $trimmedRootPath.EndsWith('"')) {
        $trimmedRootPath = $trimmedRootPath.Substring(1, $trimmedRootPath.Length - 2)
    }

    if ($trimmedRootPath -match '^[a-z][a-z0-9+\.-]*://' -or $trimmedRootPath -match '^[a-z]+:[^\\/]') {
        $Argument2 = $Argument1
        $Argument1 = $RootPath
        $RootPath = $null
    } else {
        $RootPath = $trimmedRootPath
    }
}

if (-not (Get-Variable -Name ZapretRootDir -Scope Script -ErrorAction SilentlyContinue)) {
    if ($RootPath) {
        $script:ZapretRootDir = [System.IO.Path]::GetFullPath($RootPath)
    } else {
        $script:ZapretRootDir = Split-Path -Parent $PSScriptRoot
    }
}

$script:DummyIpsetEntry = "203.0.113.113/32"
$script:ManagedHostsBegin = "# BEGIN zapret-discord-youtube"
$script:ManagedHostsEnd = "# END zapret-discord-youtube"

function Get-Utf8NoBomEncoding {
    New-Object System.Text.UTF8Encoding($false)
}

function Ensure-Directory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

function New-TemporaryPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Directory,

        [Parameter(Mandatory = $true)]
        [string]$Prefix
    )

    Ensure-Directory -Path $Directory
    Join-Path $Directory ("{0}.{1}.tmp" -f $Prefix, ([guid]::NewGuid().ToString("N")))
}

function Get-StagingDirectory {
    $baseTemp = $env:TEMP
    if ([string]::IsNullOrWhiteSpace($baseTemp)) {
        $baseTemp = [System.IO.Path]::GetTempPath()
    }

    $stagingDirectory = Join-Path $baseTemp "zapret-discord-youtube"
    Ensure-Directory -Path $stagingDirectory

    return $stagingDirectory
}

function Read-FileText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (Test-Path $Path -PathType Leaf) {
        return [System.IO.File]::ReadAllText($Path)
    }

    return ""
}

function Normalize-LineEndings {
    param(
        [AllowNull()]
        [string]$Text
    )

    if ($null -eq $Text) {
        return ""
    }

    return (($Text -replace "`r`n", "`n") -replace "`r", "`n")
}

function Normalize-ComparableText {
    param(
        [AllowNull()]
        [string]$Text
    )

    return (Normalize-LineEndings -Text $Text).TrimEnd("`n")
}

function Split-NormalizedLines {
    param(
        [AllowNull()]
        [string]$Text
    )

    $normalized = Normalize-LineEndings -Text $Text
    if ($normalized.Length -eq 0) {
        return @()
    }

    return @($normalized -split "`n", -1)
}

function Trim-BlankEdgeLines {
    param(
        [string[]]$Lines
    )

    if ($null -eq $Lines -or $Lines.Count -eq 0) {
        return @()
    }

    $start = 0
    $end = $Lines.Count - 1

    while ($start -le $end -and [string]::IsNullOrWhiteSpace($Lines[$start])) {
        $start++
    }

    while ($end -ge $start -and [string]::IsNullOrWhiteSpace($Lines[$end])) {
        $end--
    }

    if ($start -gt $end) {
        return @()
    }

    return @($Lines[$start..$end])
}

function Get-ExactLineIndexes {
    param(
        [string[]]$Lines,
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $indexes = @()
    if ($null -eq $Lines) {
        return $indexes
    }

    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -eq $Value) {
            $indexes += $i
        }
    }

    return @($indexes)
}

function Write-FileAtomically {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Content,

        [string]$BackupPath
    )

    $directory = Split-Path -Parent $Path
    Ensure-Directory -Path $directory
    $temporaryPath = New-TemporaryPath -Directory $directory -Prefix "write"
    $replaceBackupPath = $BackupPath

    if ($replaceBackupPath) {
        Ensure-Directory -Path (Split-Path -Parent $replaceBackupPath)
    }

    try {
        [System.IO.File]::WriteAllText($temporaryPath, $Content, (Get-Utf8NoBomEncoding))

        if (Test-Path $Path -PathType Leaf) {
            if (-not $replaceBackupPath) {
                $replaceBackupPath = New-TemporaryPath -Directory $directory -Prefix "write-backup"
            }

            [System.IO.File]::Replace($temporaryPath, $Path, $replaceBackupPath, $true)
        } else {
            [System.IO.File]::Move($temporaryPath, $Path)
        }
    } finally {
        if (Test-Path $temporaryPath -PathType Leaf) {
            Remove-Item $temporaryPath -Force -ErrorAction SilentlyContinue
        }

        if (-not $BackupPath -and $replaceBackupPath -and (Test-Path $replaceBackupPath -PathType Leaf)) {
            Remove-Item $replaceBackupPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Replace-FileAtomically {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,

        [string]$BackupPath
    )

    if (-not (Test-Path $SourcePath -PathType Leaf)) {
        throw "Source file not found: $SourcePath"
    }

    $directory = Split-Path -Parent $DestinationPath
    Ensure-Directory -Path $directory
    $temporaryPath = New-TemporaryPath -Directory $directory -Prefix "replace"
    $replaceBackupPath = $BackupPath

    if ($replaceBackupPath) {
        Ensure-Directory -Path (Split-Path -Parent $replaceBackupPath)
    }

    try {
        [System.IO.File]::Copy($SourcePath, $temporaryPath, $true)

        if (Test-Path $DestinationPath -PathType Leaf) {
            if (-not $replaceBackupPath) {
                $replaceBackupPath = New-TemporaryPath -Directory $directory -Prefix "replace-backup"
            }

            [System.IO.File]::Replace($temporaryPath, $DestinationPath, $replaceBackupPath, $true)
        } else {
            [System.IO.File]::Move($temporaryPath, $DestinationPath)
        }
    } finally {
        if (Test-Path $temporaryPath -PathType Leaf) {
            Remove-Item $temporaryPath -Force -ErrorAction SilentlyContinue
        }

        if (-not $BackupPath -and $replaceBackupPath -and (Test-Path $replaceBackupPath -PathType Leaf)) {
            Remove-Item $replaceBackupPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-IpsetPaths {
    $listsDir = Join-Path $script:ZapretRootDir "lists"

    New-Object PSObject -Property @{
        ListsDir   = $listsDir
        ActiveFile = Join-Path $listsDir "ipset-all.txt"
        LoadedFile = Join-Path $listsDir "ipset-all.txt.loaded"
        BackupFile = Join-Path $listsDir "ipset-all.txt.backup"
        StateFile  = Join-Path $listsDir "ipset-all.state"
    }
}

function Test-IpsetMode {
    param(
        [AllowNull()]
        [string]$Mode
    )

    if ([string]::IsNullOrWhiteSpace($Mode)) {
        return $false
    }

    return @("loaded", "any", "none") -contains $Mode.Trim().ToLowerInvariant()
}

function Get-LegacyIpsetMode {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ActiveFile
    )

    if (-not (Test-Path $ActiveFile -PathType Leaf)) {
        return "none"
    }

    $lines = @(Get-Content -Path $ActiveFile)
    $nonEmptyLines = @($lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    if ($nonEmptyLines.Count -eq 0) {
        return "any"
    }

    if ($nonEmptyLines.Count -eq 1 -and $nonEmptyLines[0].Trim() -eq $script:DummyIpsetEntry) {
        return "none"
    }

    return "loaded"
}

function Test-IpsetLine {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Line
    )

    $trimmed = $Line.Trim()
    if ($trimmed.Length -eq 0 -or $trimmed.StartsWith("#") -or $trimmed.StartsWith(";")) {
        return $true
    }

    $match = [regex]::Match($trimmed, '^(?<ip>[^/\s]+)(?:/(?<mask>\d{1,3}))?$')
    if (-not $match.Success) {
        return $false
    }

    $parsedIp = $null
    if (-not [System.Net.IPAddress]::TryParse($match.Groups["ip"].Value, [ref]$parsedIp)) {
        return $false
    }

    if ($match.Groups["mask"].Success) {
        [int]$maskValue = $match.Groups["mask"].Value
        $maxMask = 32
        if ($parsedIp.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) {
            $maxMask = 128
        }

        if ($maskValue -lt 0 -or $maskValue -gt $maxMask) {
            return $false
        }
    }

    return $true
}

function Validate-IpsetContent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content
    )

    $lines = Split-NormalizedLines -Text $Content
    $entryCount = 0

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i].Trim()
        if ($line.Length -eq 0 -or $line.StartsWith("#") -or $line.StartsWith(";")) {
            continue
        }

        if (-not (Test-IpsetLine -Line $line)) {
            throw "Invalid IPSet entry at line $($i + 1): $line"
        }

        $entryCount++
    }

    if ($entryCount -eq 0) {
        throw "Downloaded IPSet list is empty."
    }
}

function Initialize-IpsetState {
    $paths = Get-IpsetPaths
    Ensure-Directory -Path $paths.ListsDir

    $legacyMode = Get-LegacyIpsetMode -ActiveFile $paths.ActiveFile
    $state = $null

    if (Test-Path $paths.StateFile -PathType Leaf) {
        $candidate = (Read-FileText -Path $paths.StateFile).Trim().ToLowerInvariant()
        if (Test-IpsetMode -Mode $candidate) {
            $state = $candidate
        }
    }

    if (-not $state) {
        $state = $legacyMode
        if ($state -eq "none" -and (Test-Path $paths.LoadedFile -PathType Leaf)) {
            $state = "loaded"
        }

        Write-FileAtomically -Path $paths.StateFile -Content ($state + "`r`n")
    }

    if (-not (Test-Path $paths.LoadedFile -PathType Leaf)) {
        if ($legacyMode -eq "loaded" -and (Test-Path $paths.ActiveFile -PathType Leaf)) {
            Replace-FileAtomically -SourcePath $paths.ActiveFile -DestinationPath $paths.LoadedFile
        } elseif (Test-Path $paths.BackupFile -PathType Leaf) {
            [System.IO.File]::Move($paths.BackupFile, $paths.LoadedFile)
        }
    }

    if ($state -eq "loaded" -and -not (Test-Path $paths.LoadedFile -PathType Leaf) -and $legacyMode -ne "loaded") {
        $state = $legacyMode
        Write-FileAtomically -Path $paths.StateFile -Content ($state + "`r`n")
    }

    return $state
}

function Get-IpsetStatus {
    Initialize-IpsetState
}

function Write-IpsetActiveFileForMode {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Mode
    )

    $paths = Get-IpsetPaths

    switch ($Mode) {
        "loaded" {
            if (-not (Test-Path $paths.LoadedFile -PathType Leaf)) {
                throw "No cached IPSet list found. Update the list first."
            }

            Validate-IpsetContent -Content (Read-FileText -Path $paths.LoadedFile)
            Replace-FileAtomically -SourcePath $paths.LoadedFile -DestinationPath $paths.ActiveFile
        }
        "any" {
            Write-FileAtomically -Path $paths.ActiveFile -Content ""
        }
        "none" {
            Write-FileAtomically -Path $paths.ActiveFile -Content ($script:DummyIpsetEntry + "`r`n")
        }
        default {
            throw "Unsupported IPSet mode: $Mode"
        }
    }
}

function Set-IpsetMode {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Mode
    )

    $targetMode = $Mode.Trim().ToLowerInvariant()
    if (-not (Test-IpsetMode -Mode $targetMode)) {
        throw "Invalid IPSet mode: $Mode"
    }

    $paths = Get-IpsetPaths
    $currentMode = Initialize-IpsetState

    if ($currentMode -eq $targetMode) {
        return $targetMode
    }

    try {
        Write-IpsetActiveFileForMode -Mode $targetMode
        Write-FileAtomically -Path $paths.StateFile -Content ($targetMode + "`r`n")
    } catch {
        try {
            Write-IpsetActiveFileForMode -Mode $currentMode
        } catch {
        }

        throw
    }

    return $targetMode
}

function Get-NextIpsetMode {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Mode
    )

    switch ($Mode) {
        "loaded" { return "none" }
        "none" { return "any" }
        default { return "loaded" }
    }
}

function Switch-IpsetMode {
    $currentMode = Get-IpsetStatus
    $nextMode = Get-NextIpsetMode -Mode $currentMode

    Write-Host ("Switching IPSet mode from '{0}' to '{1}'..." -f $currentMode, $nextMode) -ForegroundColor Cyan
    Set-IpsetMode -Mode $nextMode | Out-Null
    Write-Host ("IPSet mode is now '{0}'." -f $nextMode) -ForegroundColor Green

    return $nextMode
}

function Download-TextFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    Ensure-Directory -Path (Split-Path -Parent $DestinationPath)

    try {
        $previousProgressPreference = $ProgressPreference
        $ProgressPreference = "SilentlyContinue"
        Invoke-WebRequest -Uri $Url -TimeoutSec 20 -UseBasicParsing -OutFile $DestinationPath
    } catch {
        $downloadError = $_.Exception.Message
        $curl = Get-Command "curl.exe" -ErrorAction SilentlyContinue
        if (-not $curl) {
            throw "Failed to download $Url. $downloadError"
        }

        & $curl.Source -L --fail --silent --show-error -o $DestinationPath $Url
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to download $Url. PowerShell downloader: $downloadError"
        }
    } finally {
        $ProgressPreference = $previousProgressPreference
    }
}

function Update-IpsetList {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url
    )

    $paths = Get-IpsetPaths
    $currentMode = Get-IpsetStatus
    $stagingDirectory = Get-StagingDirectory
    $temporaryPath = New-TemporaryPath -Directory $stagingDirectory -Prefix "ipset-download"
    $activeRollbackPath = $null

    try {
        Write-Host "Downloading IPSet list..." -ForegroundColor Cyan
        Download-TextFile -Url $Url -DestinationPath $temporaryPath

        Write-Host "Download complete. Validating IPSet list..." -ForegroundColor DarkGray
        $downloadedContent = Read-FileText -Path $temporaryPath
        Validate-IpsetContent -Content $downloadedContent

        if ($currentMode -eq "loaded" -and (Test-Path $paths.ActiveFile -PathType Leaf)) {
            $activeRollbackPath = New-TemporaryPath -Directory $stagingDirectory -Prefix "ipset-active-rollback"
            [System.IO.File]::Copy($paths.ActiveFile, $activeRollbackPath, $true)
        }

        Write-Host "Applying IPSet update..." -ForegroundColor DarkGray
        Replace-FileAtomically -SourcePath $temporaryPath -DestinationPath $paths.LoadedFile -BackupPath $paths.BackupFile

        if ($currentMode -eq "loaded") {
            try {
                Replace-FileAtomically -SourcePath $paths.LoadedFile -DestinationPath $paths.ActiveFile
            } catch {
                if (Test-Path $paths.BackupFile -PathType Leaf) {
                    Replace-FileAtomically -SourcePath $paths.BackupFile -DestinationPath $paths.LoadedFile
                } elseif ($activeRollbackPath -and (Test-Path $activeRollbackPath -PathType Leaf)) {
                    Replace-FileAtomically -SourcePath $activeRollbackPath -DestinationPath $paths.LoadedFile
                }

                if ($activeRollbackPath -and (Test-Path $activeRollbackPath -PathType Leaf)) {
                    Replace-FileAtomically -SourcePath $activeRollbackPath -DestinationPath $paths.ActiveFile
                }

                throw
            }
        }

        Write-Host "IPSet list updated successfully." -ForegroundColor Green
        if ($currentMode -ne "loaded") {
            Write-Host ("Cached list updated; active mode remains '{0}'." -f $currentMode) -ForegroundColor DarkGray
        }
    } finally {
        if (Test-Path $temporaryPath -PathType Leaf) {
            Remove-Item $temporaryPath -Force -ErrorAction SilentlyContinue
        }

        if ($activeRollbackPath -and (Test-Path $activeRollbackPath -PathType Leaf)) {
            Remove-Item $activeRollbackPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-ManagedHostsPayloadLines {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $lines = @(Split-NormalizedLines -Text $Text)
    if ($lines.Count -gt 0) {
        $lines[0] = $lines[0].TrimStart([char]0xFEFF)
    }

    $beginIndexes = @(Get-ExactLineIndexes -Lines $lines -Value $script:ManagedHostsBegin)
    $endIndexes = @(Get-ExactLineIndexes -Lines $lines -Value $script:ManagedHostsEnd)

    if (($beginIndexes.Count + $endIndexes.Count) -gt 0) {
        if ($beginIndexes.Count -ne 1 -or $endIndexes.Count -ne 1 -or $beginIndexes[0] -ge $endIndexes[0]) {
            throw "Downloaded hosts content contains invalid managed block markers."
        }

        if (($endIndexes[0] - $beginIndexes[0]) -gt 1) {
            $lines = @($lines[($beginIndexes[0] + 1)..($endIndexes[0] - 1)])
        } else {
            $lines = @()
        }
    }

    $lines = @(Trim-BlankEdgeLines -Lines $lines)
    if ($lines.Count -eq 0) {
        throw "Downloaded hosts block is empty."
    }

    return @($lines)
}

function Merge-ManagedHostsBlock {
    param(
        [AllowNull()]
        [string]$CurrentText,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string[]]$ManagedPayloadLines
    )

    $lines = @(Split-NormalizedLines -Text $CurrentText)
    if ($lines.Count -gt 0) {
        $lines[0] = $lines[0].TrimStart([char]0xFEFF)
    }

    $beginIndexes = @(Get-ExactLineIndexes -Lines $lines -Value $script:ManagedHostsBegin)
    $endIndexes = @(Get-ExactLineIndexes -Lines $lines -Value $script:ManagedHostsEnd)

    if ($beginIndexes.Count -ne $endIndexes.Count) {
        throw "Hosts file contains an incomplete managed block."
    }

    if ($beginIndexes.Count -gt 1) {
        throw "Hosts file contains multiple managed blocks."
    }

    $managedBlock = @($script:ManagedHostsBegin) + $ManagedPayloadLines + @($script:ManagedHostsEnd)

    if ($beginIndexes.Count -eq 1) {
        if ($beginIndexes[0] -ge $endIndexes[0]) {
            throw "Hosts file contains a malformed managed block."
        }

        $before = @()
        $after = @()

        if ($beginIndexes[0] -gt 0) {
            $before = @($lines[0..($beginIndexes[0] - 1)])
        }

        if (($endIndexes[0] + 1) -lt $lines.Count) {
            $after = @($lines[($endIndexes[0] + 1)..($lines.Count - 1)])
        }

        $mergedLines = @($before + $managedBlock + $after)
    } else {
        $mergedLines = @($lines)

        while ($mergedLines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($mergedLines[$mergedLines.Count - 1])) {
            if ($mergedLines.Count -eq 1) {
                $mergedLines = @()
            } else {
                $mergedLines = @($mergedLines[0..($mergedLines.Count - 2)])
            }
        }

        if ($mergedLines.Count -gt 0) {
            $mergedLines += ""
        }

        $mergedLines += $managedBlock
    }

    return (($mergedLines -join "`r`n") + "`r`n")
}

function Update-HostsFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [string]$HostsFilePath = (Join-Path $env:SystemRoot "System32\drivers\etc\hosts")
    )

    $hostsDirectory = Split-Path -Parent $HostsFilePath
    $stagingDirectory = Get-StagingDirectory
    $temporaryPath = New-TemporaryPath -Directory $stagingDirectory -Prefix "hosts-download"
    $backupPath = Join-Path $hostsDirectory "hosts.zapret-discord-youtube.backup"

    try {
        Write-Host "Downloading hosts block..." -ForegroundColor Cyan
        Download-TextFile -Url $Url -DestinationPath $temporaryPath

        Write-Host "Download complete. Preparing hosts merge..." -ForegroundColor DarkGray
        $payloadLines = Get-ManagedHostsPayloadLines -Text (Read-FileText -Path $temporaryPath)
        $currentText = Read-FileText -Path $HostsFilePath
        $mergedText = Merge-ManagedHostsBlock -CurrentText $currentText -ManagedPayloadLines $payloadLines

        if ((Normalize-ComparableText -Text $currentText) -eq (Normalize-ComparableText -Text $mergedText)) {
            Write-Host "Hosts file is up to date." -ForegroundColor Green
            return $false
        }

        Write-Host "Applying hosts update..." -ForegroundColor DarkGray
        Write-FileAtomically -Path $HostsFilePath -Content $mergedText -BackupPath $backupPath
        Write-Host "Hosts file updated successfully." -ForegroundColor Green
        Write-Host "Backup saved to $backupPath" -ForegroundColor DarkGray

        return $true
    } finally {
        if (Test-Path $temporaryPath -PathType Leaf) {
            Remove-Item $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

if ($CommandName) {
    try {
        switch ($CommandName.Trim().ToLowerInvariant()) {
            "get-ipset-status" {
                Write-Output (Get-IpsetStatus)
            }
            "switch-ipset" {
                Switch-IpsetMode | Out-Null
            }
            "set-ipset-mode" {
                if (-not $Argument1) {
                    throw "IPSet mode is required."
                }

                Set-IpsetMode -Mode $Argument1 | Out-Null
            }
            "update-ipset" {
                if (-not $Argument1) {
                    throw "IPSet URL is required."
                }

                Update-IpsetList -Url $Argument1
            }
            "update-hosts" {
                if (-not $Argument1) {
                    throw "Hosts URL is required."
                }

                if ($Argument2) {
                    Update-HostsFile -Url $Argument1 -HostsFilePath $Argument2 | Out-Null
                } else {
                    Update-HostsFile -Url $Argument1 | Out-Null
                }
            }
            default {
                throw "Unknown command: $CommandName"
            }
        }
    } catch {
        Write-Host ("[ERROR] {0}" -f $_.Exception.Message) -ForegroundColor Red
        exit 1
    }
}
