# Zapret GUI - Update Functions

class UpdateInfo {
    [bool]$Available
    [string]$LatestVersion
    [string]$CurrentVersion
    [string]$ReleaseUrl
    [string]$DownloadUrl
    [string]$Error
    
    UpdateInfo() {
        $this.Available = $false
        $this.LatestVersion = ""
        $this.CurrentVersion = ""
        $this.ReleaseUrl = ""
        $this.DownloadUrl = ""
        $this.Error = ""
    }
}

function Compare-SemanticVersion {
    param([string]$V1, [string]$V2)
    
    $p1 = $V1.Split('.') | ForEach-Object { [int]$_ }
    $p2 = $V2.Split('.') | ForEach-Object { [int]$_ }
    
    $max = [Math]::Max($p1.Count, $p2.Count)
    while ($p1.Count -lt $max) { $p1 += 0 }
    while ($p2.Count -lt $max) { $p2 += 0 }
    
    for ($i = 0; $i -lt $max; $i++) {
        if ($p1[$i] -gt $p2[$i]) { return 1 }
        if ($p1[$i] -lt $p2[$i]) { return -1 }
    }
    return 0
}

function Test-NewVersionAvailable {
    $result = [UpdateInfo]::new()
    $result.CurrentVersion = $script:Config.Version
    
    try {
        $request = [System.Net.WebRequest]::Create($script:Config.GitHubVersionUrl)
        $request.Timeout = 10000
        $request.Headers.Add("Cache-Control", "no-cache")
        
        $response = $request.GetResponse()
        $stream = $response.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($stream)
        $latest = $reader.ReadToEnd().Trim()
        $reader.Close()
        $response.Close()
        
        if (-not $latest) {
            $result.Error = "Empty version response"
            return $result
        }
        
        $result.LatestVersion = $latest
        $result.ReleaseUrl = "$($script:Config.GitHubReleaseUrl)$latest"
        $result.DownloadUrl = "$($script:Config.GitHubDownloadUrl)$latest.rar"
        
        $cmp = Compare-SemanticVersion -V1 $latest -V2 $script:Config.Version
        $result.Available = ($cmp -gt 0)
        
        return $result
    }
    catch [System.Net.WebException] {
        $result.Error = "Network error"
        return $result
    }
    catch {
        $result.Error = $_.Exception.Message
        return $result
    }
}
