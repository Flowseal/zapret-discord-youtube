param(
    [string]$HostsFile,
    [string]$ReferenceFile
)

function Get-HostsEntries([string]$Path) {
    foreach ($line in (Get-Content -LiteralPath $Path -ErrorAction Stop)) {
        $fields = ($line -split "#", 2)[0].Trim() -split "\s+"
        $address = $null
        if ($fields.Count -lt 2 -or -not [Net.IPAddress]::TryParse($fields[0], [ref]$address)) {
            continue
        }
        for ($index = 1; $index -lt $fields.Count; $index++) {
            "$address $($fields[$index])"
        }
    }
}

try {
    $referenceEntries = @(Get-HostsEntries $ReferenceFile)
    if ($referenceEntries.Count -eq 0) {
        throw "The downloaded hosts file has no entries."
    }

    $localEntries = @{}
    if (Test-Path -LiteralPath $HostsFile -ErrorAction Stop) {
        foreach ($entry in (Get-HostsEntries $HostsFile)) {
            $localEntries[$entry] = $true
        }
    }
    $missingEntries = @($referenceEntries | Where-Object { -not $localEntries.ContainsKey($_) })
    if ($missingEntries.Count -gt 0) {
        Write-Host "Missing or outdated hosts entries:"
        $missingEntries | Write-Host
        exit 2
    }
    exit 0
} catch {
    Write-Error $_ -ErrorAction Continue
    exit 1
}
