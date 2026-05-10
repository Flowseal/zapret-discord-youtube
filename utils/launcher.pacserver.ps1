#Requires -Version 5.1
<#
.SYNOPSIS
  Tiny localhost HTTP server for the launcher's PAC file.
.DESCRIPTION
  Modern browsers (Chrome 81+, Firefox, Edge) treat file:// PAC URLs
  inconsistently. Serving the PAC over http://127.0.0.1:<port>/launcher.pac is
  universally supported. Re-reads the PAC on every request, so toggling
  Geo-services in the launcher takes effect without restarting this server.

  Usage (spawned by the launcher; not meant to be run by hand):
    powershell -NoProfile -WindowStyle Hidden -File launcher.pacserver.ps1 \
        -PacPath C:\...\launcher.pac -Port 27289
#>

param(
    [Parameter(Mandatory=$true)] [string]$PacPath,
    [Parameter(Mandatory=$true)] [int]   $Port
)

$ErrorActionPreference = 'Stop'

$prefix = "http://127.0.0.1:$Port/"
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($prefix)
try {
    $listener.Start()
} catch {
    Write-Error "Failed to bind $prefix : $_"
    exit 2
}

# Trap Ctrl-C / parent termination cleanly.
$cancelHandler = [System.ConsoleCancelEventHandler] {
    param($sender, $e)
    $e.Cancel = $true
    try { $listener.Stop() } catch { }
}
[Console]::add_CancelKeyPress($cancelHandler)

$fallbackPac = @'
function FindProxyForURL(url, host) { return "DIRECT"; }
'@

try {
    while ($listener.IsListening) {
        $ctx = $null
        try { $ctx = $listener.GetContext() } catch { break }
        if (-not $ctx) { continue }

        $body = $fallbackPac
        if (Test-Path -LiteralPath $PacPath) {
            try { $body = [IO.File]::ReadAllText($PacPath) } catch { $body = $fallbackPac }
        }

        $bytes = [Text.Encoding]::UTF8.GetBytes($body)
        try {
            $ctx.Response.ContentType     = 'application/x-ns-proxy-autoconfig'
            $ctx.Response.ContentLength64 = $bytes.Length
            $ctx.Response.AddHeader('Cache-Control', 'no-store')
            $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
            $ctx.Response.OutputStream.Flush()
        } catch { }
        try { $ctx.Response.Close() } catch { }
    }
} finally {
    try { $listener.Stop() } catch { }
    try { $listener.Close() } catch { }
}
