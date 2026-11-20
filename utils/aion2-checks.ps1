# Pure diagnostic helpers. Compatible with Windows PowerShell 5.1.
function Test-AionIPv4InCidr {
    param([string]$Address,[string]$Cidr)
    if ($Cidr -notmatch '^(\d{1,3}\.){3}\d{1,3}/(3[0-2]|[12]?\d)$') { return $false }
    try {
        $parts = $Cidr.Split('/')
        $a = [Net.IPAddress]::Parse($Address)
        $b = [Net.IPAddress]::Parse($parts[0])
        if ($a.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or $b.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { return $false }
        $bytesA = $a.GetAddressBytes()
        $bytesB = $b.GetAddressBytes()
        $bits = [int]$parts[1]
        for ($i=0; $i -lt 4; $i++) {
            $maskBits = [math]::Max(0,[math]::Min(8,$bits - 8*$i))
            $mask = if ($maskBits -eq 0) { 0 } else { (255 -shl (8-$maskBits)) -band 255 }
            if (($bytesA[$i] -band $mask) -ne ($bytesB[$i] -band $mask)) { return $false }
        }
        return $true
    } catch { return $false }
}
function Test-AionIPSet {
    param([string]$Address,[string[]]$Lines)
    if (-not $Lines -or $Lines.Count -eq 0) { return 'any' }
    $tokens = @($Lines | ForEach-Object { ($_ -split '#',2)[0].Trim() } | Where-Object { $_ })
    if ($tokens.Count -eq 0) { return 'any' }
    if ($tokens.Count -eq 1 -and $tokens[0] -eq '203.0.113.113/32') { return 'none' }
    foreach ($line in $tokens) {
        if ($line -eq $Address -or (Test-AionIPv4InCidr -Address $Address -Cidr $line)) { return 'included' }
    }
    return 'excluded'
}
function Test-AionPortInRange {
    param([int]$Port,[string]$Ranges)
    foreach ($range in @($Ranges -split ',')) {
        $range = $range.Trim()
        if ($range -match '^(\d{1,5})$') {
            if ($Port -eq [int]$matches[1]) { return $true }
        } elseif ($range -match '^(\d{1,5})-(\d{1,5})$') {
            if ($Port -ge [int]$matches[1] -and $Port -le [int]$matches[2]) { return $true }
        }
    }
    return $false
}
function Get-AionStats {
    param([double[]]$Measurements,[int]$Attempts)
    if ($Attempts -lt 1) { throw 'Attempts must be positive' }
    $values = @($Measurements | Sort-Object)
    $count = $values.Count
    $avg = $null; $median = $null; $p95 = $null; $minimum=$null; $maximum=$null
    if ($count -gt 0) {
        $avg = [math]::Round(($values | Measure-Object -Average).Average,1)
        $minimum = $values[0]
        $maximum = $values[$count-1]
        $p95 = $values[[math]::Max(0,[math]::Ceiling($count*.95)-1)]
        if ($count % 2) { $median = $values[[math]::Floor($count/2)] }
        else { $median = [math]::Round(($values[$count/2-1]+$values[$count/2])/2,1) }
    }
    [pscustomobject]@{
        Count=$count; Attempts=$Attempts; SuccessPct=[math]::Round(100*$count/$Attempts,1)
        AvgMs=$avg; MedianMs=$median; P95Ms=$p95; MinMs=$minimum; MaxMs=$maximum
    }
}
function Get-AionRank {
    param([object[]]$Rows)
    @($Rows | Sort-Object @{Expression='Eligible';Descending=$true},
        @{Expression='DiscordOK';Descending=$true},
        @{Expression='AionTcpSuccessPct';Descending=$true},
        @{Expression={if ($null -eq $_.AionTcpP95Ms) {[double]::PositiveInfinity} else {$_.AionTcpP95Ms}};Descending=$false})
}
