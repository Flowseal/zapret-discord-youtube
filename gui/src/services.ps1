# Zapret GUI - Service Management Functions

function Get-ServiceStatus {
    param([string]$ServiceName)
    
    try {
        $output = sc.exe query $ServiceName 2>&1
        $outputStr = $output -join "`n"
        
        if ($outputStr -match "FAILED 1060" -or $outputStr -match "does not exist") {
            return "NotInstalled"
        }
        if ($outputStr -match "STATE\s+:\s+\d+\s+RUNNING") {
            return "Running"
        }
        if ($outputStr -match "STATE\s+:\s+\d+\s+(STOPPED|STOP_PENDING|START_PENDING)") {
            return "Stopped"
        }
        return "NotInstalled"
    }
    catch {
        return "NotInstalled"
    }
}

function Get-ZapretStatus {
    return Get-ServiceStatus -ServiceName "zapret"
}

function Get-WinDivertStatus {
    $status = Get-ServiceStatus -ServiceName "WinDivert"
    if ($status -ne "NotInstalled") { return $status }
    return Get-ServiceStatus -ServiceName "WinDivert14"
}

function Get-BypassProcessStatus {
    try {
        $process = Get-Process -Name "winws" -ErrorAction SilentlyContinue
        if ($process) { return "Active" }
        return "Inactive"
    }
    catch {
        return "Inactive"
    }
}

function Get-InstalledStrategy {
    try {
        if ((Get-ZapretStatus) -eq "NotInstalled") { return $null }
        
        $regPath = "HKLM:\System\CurrentControlSet\Services\zapret"
        if (Test-Path $regPath) {
            $prop = Get-ItemProperty -Path $regPath -Name "zapret-discord-youtube" -ErrorAction SilentlyContinue
            if ($prop -and $prop."zapret-discord-youtube") {
                return $prop."zapret-discord-youtube"
            }
        }
        return $null
    }
    catch {
        return $null
    }
}

function Get-AvailableStrategies {
    $strategies = Get-ChildItem -Path $script:RootDir -Filter "*.bat" -ErrorAction SilentlyContinue | 
        Where-Object { $_.Name -notlike "service*" -and $_.Name -notlike "gui*" } |
        Select-Object -ExpandProperty Name |
        Sort-Object
    return $strategies
}

function Install-ZapretService {
    param([string]$StrategyFile)
    
    $strategyPath = Join-Path $script:RootDir $StrategyFile
    
    if (-not (Test-Path $strategyPath)) {
        return @{ Success = $false; Message = "Strategy file not found: $StrategyFile" }
    }
    
    if (-not (Test-Path $script:BinDir)) {
        return @{ Success = $false; Message = "bin folder not found" }
    }
    
    # Check Game Filter status
    $gameFilterFile = Join-Path $script:UtilsDir "game_filter.enabled"
    $GameFilter = if (Test-Path $gameFilterFile) { "1024-65535" } else { "12" }
    
    # Read bat file
    $batContent = Get-Content -Path $strategyPath -Raw -ErrorAction SilentlyContinue
    if (-not $batContent) {
        return @{ Success = $false; Message = "Cannot read strategy file" }
    }
    
    # Find winws.exe command
    $lines = $batContent -split "`r?`n"
    $capturing = $false
    $fullCommand = ""
    
    foreach ($line in $lines) {
        if ($line -match 'winws\.exe') { $capturing = $true }
        if ($capturing) {
            $cleanLine = $line -replace '\^$', ''
            $fullCommand += $cleanLine + " "
            if ($line -notmatch '\^$') { break }
        }
    }
    
    if (-not $fullCommand) {
        return @{ Success = $false; Message = "winws.exe command not found in strategy" }
    }
    
    # Extract arguments
    $argsMatch = $fullCommand -match 'winws\.exe["\s]+(.+)$'
    if (-not $argsMatch) {
        $argsMatch = $fullCommand -match 'winws\.exe(.+)$'
    }
    
    if (-not $argsMatch) {
        return @{ Success = $false; Message = "Cannot parse winws.exe arguments" }
    }
    
    $rawArgs = $Matches[1].Trim()
    
    # Replace variables
    $processedArgs = $rawArgs
    $processedArgs = $processedArgs -replace '%BIN%', $script:BinDir
    $processedArgs = $processedArgs -replace '"%BIN%', "`"$($script:BinDir)"
    $processedArgs = $processedArgs -replace '%LISTS%', $script:ListsDir
    $processedArgs = $processedArgs -replace '"%LISTS%', "`"$($script:ListsDir)"
    $processedArgs = $processedArgs -replace '%GameFilter%', $GameFilter
    $processedArgs = $processedArgs -replace '\s+', ' '
    $processedArgs = $processedArgs.Trim()
    $processedArgs = $processedArgs -replace '^start\s+"[^"]*"\s+/min\s+', ''
    $processedArgs = $processedArgs -replace '^"[^"]*winws\.exe"\s*', ''
    
    # Enable TCP timestamps
    try { $null = netsh interface tcp set global timestamps=enabled 2>&1 } catch {}
    
    # Remove existing service
    $existing = Get-ServiceStatus -ServiceName "zapret"
    if ($existing -ne "NotInstalled") {
        $null = net stop zapret 2>&1
        $null = sc.exe delete zapret 2>&1
        Start-Sleep -Milliseconds 500
    }
    
    # Create service
    $winwsPath = Join-Path $script:BinDir "winws.exe"
    $binPathArg = "`"$winwsPath`" $processedArgs"
    
    $result = sc.exe create zapret binPath= $binPathArg DisplayName= "zapret" start= auto 2>&1
    if ($LASTEXITCODE -ne 0) {
        return @{ Success = $false; Message = "Failed to create service: $result" }
    }
    
    $null = sc.exe description zapret "Zapret DPI bypass software" 2>&1
    
    # Start service
    $startResult = sc.exe start zapret 2>&1
    
    # Save strategy name
    $strategyName = [System.IO.Path]::GetFileNameWithoutExtension($StrategyFile)
    try {
        $regPath = "HKLM:\System\CurrentControlSet\Services\zapret"
        if (Test-Path $regPath) {
            Set-ItemProperty -Path $regPath -Name "zapret-discord-youtube" -Value $strategyName -ErrorAction Stop
        }
    } catch {}
    
    return @{ Success = $true; Message = "Service installed: $strategyName" }
}

function Remove-ZapretServices {
    $messages = @()
    
    # Stop zapret
    $zapretStatus = Get-ServiceStatus -ServiceName "zapret"
    if ($zapretStatus -ne "NotInstalled") {
        $null = net stop zapret 2>&1
        Start-Sleep -Milliseconds 300
        $null = sc.exe delete zapret 2>&1
        $messages += "Zapret service removed"
    }
    
    # Stop winws process
    try {
        $proc = Get-Process -Name "winws" -ErrorAction SilentlyContinue
        if ($proc) {
            Stop-Process -Name "winws" -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 300
        }
    } catch {}
    
    # Remove WinDivert
    $wdStatus = Get-ServiceStatus -ServiceName "WinDivert"
    if ($wdStatus -ne "NotInstalled") {
        $null = net stop WinDivert 2>&1
        Start-Sleep -Milliseconds 300
        $null = sc.exe delete WinDivert 2>&1
        $messages += "WinDivert removed"
    }
    
    # Remove WinDivert14
    $wd14Status = Get-ServiceStatus -ServiceName "WinDivert14"
    if ($wd14Status -ne "NotInstalled") {
        $null = net stop WinDivert14 2>&1
        Start-Sleep -Milliseconds 300
        $null = sc.exe delete WinDivert14 2>&1
        $messages += "WinDivert14 removed"
    }
    
    if ($messages.Count -eq 0) {
        $messages += "No services to remove"
    }
    
    return @{ Success = $true; Messages = $messages }
}
