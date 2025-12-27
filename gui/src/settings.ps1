# Zapret GUI - Settings Functions

function Get-GameFilterStatus {
    $file = Join-Path $script:UtilsDir "game_filter.enabled"
    return (Test-Path $file)
}

function Set-GameFilter {
    param([bool]$Enabled)
    
    $file = Join-Path $script:UtilsDir "game_filter.enabled"
    
    if ($Enabled) {
        if (-not (Test-Path $script:UtilsDir)) {
            New-Item -Path $script:UtilsDir -ItemType Directory -Force | Out-Null
        }
        New-Item -Path $file -ItemType File -Force | Out-Null
        return $true
    } else {
        if (Test-Path $file) {
            Remove-Item -Path $file -Force
        }
        return $true
    }
}

function Get-AutoUpdateStatus {
    $file = Join-Path $script:UtilsDir "check_updates.enabled"
    return (Test-Path $file)
}

function Set-AutoUpdate {
    param([bool]$Enabled)
    
    $file = Join-Path $script:UtilsDir "check_updates.enabled"
    
    if ($Enabled) {
        if (-not (Test-Path $script:UtilsDir)) {
            New-Item -Path $script:UtilsDir -ItemType Directory -Force | Out-Null
        }
        New-Item -Path $file -ItemType File -Force | Out-Null
        return $true
    } else {
        if (Test-Path $file) {
            Remove-Item -Path $file -Force
        }
        return $true
    }
}

function Get-IPsetMode {
    $ipsetFile = Join-Path $script:ListsDir "ipset-all.txt"
    
    if (Test-Path $ipsetFile) {
        $content = Get-Content -Path $ipsetFile -Raw -ErrorAction SilentlyContinue
        if ($content -and $content.Trim().Length -gt 0) {
            if ($content -match "0\.0\.0\.0/0") {
                return "any"
            }
            return "loaded"
        }
    }
    return "none"
}

function Set-IPsetMode {
    param([string]$Mode)
    
    $ipsetFile = Join-Path $script:ListsDir "ipset-all.txt"
    $backupFile = Join-Path $script:ListsDir "ipset-all.txt.backup"
    
    if (-not (Test-Path $script:ListsDir)) {
        New-Item -Path $script:ListsDir -ItemType Directory -Force | Out-Null
    }
    
    switch ($Mode) {
        "none" {
            if (Test-Path $ipsetFile) {
                $content = Get-Content -Path $ipsetFile -Raw -ErrorAction SilentlyContinue
                if ($content -and $content.Trim().Length -gt 0 -and $content -notmatch "0\.0\.0\.0/0") {
                    Copy-Item -Path $ipsetFile -Destination $backupFile -Force -ErrorAction SilentlyContinue
                }
                Remove-Item -Path $ipsetFile -Force -ErrorAction SilentlyContinue
            }
            return $true
        }
        "any" {
            if (Test-Path $ipsetFile) {
                $content = Get-Content -Path $ipsetFile -Raw -ErrorAction SilentlyContinue
                if ($content -and $content.Trim().Length -gt 0 -and $content -notmatch "0\.0\.0\.0/0") {
                    Copy-Item -Path $ipsetFile -Destination $backupFile -Force -ErrorAction SilentlyContinue
                }
            }
            Set-Content -Path $ipsetFile -Value "0.0.0.0/0" -Force
            return $true
        }
        "loaded" {
            if (Test-Path $backupFile) {
                Copy-Item -Path $backupFile -Destination $ipsetFile -Force
                return $true
            }
            return $false
        }
    }
    return $false
}

function Get-NextIPsetMode {
    $current = Get-IPsetMode
    $backupFile = Join-Path $script:ListsDir "ipset-all.txt.backup"
    
    switch ($current) {
        "none" { return "any" }
        "any" { 
            if (Test-Path $backupFile) { return "loaded" }
            return "none"
        }
        "loaded" { return "none" }
        default { return "none" }
    }
}
