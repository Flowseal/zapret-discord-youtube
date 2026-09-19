param(
    [string]$Source = (Join-Path $PSScriptRoot '..\bin\winws.exe'),
    [string]$Target = (Join-Path $PSScriptRoot '..\bin\winws-sorapret.exe')
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class SorapretResources {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern IntPtr BeginUpdateResource(string fileName, bool deleteExistingResources);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool UpdateResource(IntPtr update, IntPtr type, IntPtr name, ushort language, byte[] data, uint size);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool EndUpdateResource(IntPtr update, bool discard);
}
'@

if (-not (Test-Path -LiteralPath $Source)) { throw "winws.exe not found: $Source" }

# The artwork is stored once in set-sorapret-icon.ps1.
$artFile = Join-Path $PSScriptRoot 'set-sorapret-icon.ps1'
$raw = [IO.File]::ReadAllText($artFile)
$match = [regex]::Match($raw, "\$jpgBase64\s*=\s*'([^']+)'", [Text.RegularExpressions.RegexOptions]::Singleline)
if (-not $match.Success) { throw 'Embedded Sorapret artwork was not found.' }

$bytes = [Convert]::FromBase64String($match.Groups[1].Value)
$inputStream = New-Object IO.MemoryStream(,$bytes)
$image = [Drawing.Image]::FromStream($inputStream)
$bitmap = New-Object Drawing.Bitmap 32,32
$graphics = [Drawing.Graphics]::FromImage($bitmap)
$graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$graphics.DrawImage($image,0,0,32,32)

# Build the same 32x32, 32-bit RT_ICON layout already used by winws.exe.
$output = New-Object IO.MemoryStream
$writer = New-Object IO.BinaryWriter($output)
$writer.Write([uint32]40)
$writer.Write([int32]32)
$writer.Write([int32]64)
$writer.Write([uint16]1)
$writer.Write([uint16]32)
$writer.Write([uint32]0)
$writer.Write([uint32]4096)
$writer.Write([int32]0)
$writer.Write([int32]0)
$writer.Write([uint32]0)
$writer.Write([uint32]0)
for ($y=31; $y -ge 0; $y--) {
    for ($x=0; $x -lt 32; $x++) {
        $pixel = $bitmap.GetPixel($x,$y)
        $writer.Write([byte]$pixel.B)
        $writer.Write([byte]$pixel.G)
        $writer.Write([byte]$pixel.R)
        $writer.Write([byte]$pixel.A)
    }
}
$writer.Write((New-Object byte[] 128))
$writer.Flush()
$iconData = $output.ToArray()

Copy-Item -LiteralPath $Source -Destination $Target -Force
$handle = [SorapretResources]::BeginUpdateResource($Target,$false)
if ($handle -eq [IntPtr]::Zero) { throw "BeginUpdateResource failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
$ok = [SorapretResources]::UpdateResource($handle,[IntPtr]3,[IntPtr]1,[uint16]1033,$iconData,[uint32]$iconData.Length)
if (-not $ok) {
    $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    [void][SorapretResources]::EndUpdateResource($handle,$true)
    throw "UpdateResource failed: $err"
}
if (-not [SorapretResources]::EndUpdateResource($handle,$false)) {
    throw "EndUpdateResource failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
}

$writer.Dispose(); $output.Dispose(); $graphics.Dispose(); $bitmap.Dispose(); $image.Dispose(); $inputStream.Dispose()
Write-Host "Created $Target with the Sorapret icon. The original winws.exe was not changed." -ForegroundColor Green
