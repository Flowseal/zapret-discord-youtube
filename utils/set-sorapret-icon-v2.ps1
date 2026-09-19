param([string]$TitlePrefix = 'zapret:')

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class SorapretWindows {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc proc, IntPtr lParam);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern IntPtr SendMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
}
'@

# Reuse the embedded artwork from the original helper without duplicating it.
$sourceFile = Join-Path $PSScriptRoot 'set-sorapret-icon.ps1'
$raw = [IO.File]::ReadAllText($sourceFile)
$match = [regex]::Match($raw, "\$jpgBase64\s*=\s*'([^']+)'", [Text.RegularExpressions.RegexOptions]::Singleline)
if (-not $match.Success) { exit 2 }

$bytes = [Convert]::FromBase64String($match.Groups[1].Value)
$stream = New-Object IO.MemoryStream(,$bytes)
$image = [Drawing.Image]::FromStream($stream)
$bitmap = New-Object Drawing.Bitmap 64,64
$graphics = [Drawing.Graphics]::FromImage($bitmap)
$graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
$graphics.DrawImage($image, 0, 0, 64, 64)
$icon = $bitmap.GetHicon()

$window = [IntPtr]::Zero
for ($attempt = 0; $attempt -lt 80 -and $window -eq [IntPtr]::Zero; $attempt++) {
    [SorapretWindows]::EnumWindows({
        param($hWnd, $lParam)
        $title = New-Object Text.StringBuilder 512
        [void][SorapretWindows]::GetWindowText($hWnd, $title, $title.Capacity)
        if ($title.ToString().StartsWith($TitlePrefix, [StringComparison]::OrdinalIgnoreCase)) {
            $script:window = $hWnd
            return $false
        }
        return $true
    }, [IntPtr]::Zero) | Out-Null
    if ($window -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 250 }
}

if ($window -ne [IntPtr]::Zero) {
    # WM_SETICON: set both large and small icons on the actual top-level console window.
    [void][SorapretWindows]::SendMessage($window, 0x0080, [IntPtr]1, $icon)
    [void][SorapretWindows]::SendMessage($window, 0x0080, [IntPtr]0, $icon)
    while ([SorapretWindows]::IsWindow($window)) { Start-Sleep -Seconds 2 }
}

$graphics.Dispose()
$bitmap.Dispose()
$image.Dispose()
$stream.Dispose()
