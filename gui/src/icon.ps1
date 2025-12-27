# Zapret GUI - Icon Functions
# Creates and applies window icon (white "Z" on black background)

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

# Windows API for taskbar icon
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public class WindowsAPI {
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    
    [DllImport("shell32.dll", SetLastError = true)]
    public static extern void SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string AppID);
    
    public const uint WM_SETICON = 0x0080;
    public const int ICON_SMALL = 0;
    public const int ICON_BIG = 1;
}
"@ -ErrorAction SilentlyContinue

function Get-ZapretIconBitmap {
    param([int]$Size = 256)
    
    $bitmap = New-Object System.Drawing.Bitmap($Size, $Size)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $graphics.Clear([System.Drawing.Color]::Black)
    
    $fontSize = [Math]::Floor($Size * 0.625)
    $font = New-Object System.Drawing.Font("Segoe UI", $fontSize, [System.Drawing.FontStyle]::Bold)
    $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
    $format = New-Object System.Drawing.StringFormat
    $format.Alignment = [System.Drawing.StringAlignment]::Center
    $format.LineAlignment = [System.Drawing.StringAlignment]::Center
    
    $rect = New-Object System.Drawing.RectangleF(0, 0, $Size, $Size)
    $graphics.DrawString("Z", $font, $brush, $rect, $format)
    
    $font.Dispose()
    $brush.Dispose()
    $format.Dispose()
    $graphics.Dispose()
    
    return $bitmap
}

function New-ZapretIcon {
    param([string]$OutputPath)
    
    try {
        $bitmap = Get-ZapretIconBitmap -Size 256
        
        $sizes = @(16, 32, 48, 256)
        $images = @()
        
        foreach ($s in $sizes) {
            $resized = New-Object System.Drawing.Bitmap($s, $s)
            $g = [System.Drawing.Graphics]::FromImage($resized)
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $g.DrawImage($bitmap, 0, 0, $s, $s)
            $g.Dispose()
            
            $ms = New-Object System.IO.MemoryStream
            $resized.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
            $images += @{ Size = $s; Data = $ms.ToArray() }
            $ms.Dispose()
            $resized.Dispose()
        }
        
        $icoStream = New-Object System.IO.MemoryStream
        $writer = New-Object System.IO.BinaryWriter($icoStream)
        
        $writer.Write([UInt16]0)
        $writer.Write([UInt16]1)
        $writer.Write([UInt16]$images.Count)
        
        $dataOffset = 6 + ($images.Count * 16)
        
        foreach ($img in $images) {
            $s = $img.Size
            $writer.Write([Byte]$(if ($s -ge 256) { 0 } else { $s }))
            $writer.Write([Byte]$(if ($s -ge 256) { 0 } else { $s }))
            $writer.Write([Byte]0)
            $writer.Write([Byte]0)
            $writer.Write([UInt16]1)
            $writer.Write([UInt16]32)
            $writer.Write([UInt32]$img.Data.Length)
            $writer.Write([UInt32]$dataOffset)
            $dataOffset += $img.Data.Length
        }
        
        foreach ($img in $images) {
            $writer.Write($img.Data)
        }
        
        $writer.Flush()
        [System.IO.File]::WriteAllBytes($OutputPath, $icoStream.ToArray())
        
        $writer.Dispose()
        $icoStream.Dispose()
        $bitmap.Dispose()
        
        return $OutputPath
    }
    catch {
        return $null
    }
}

function Set-TaskbarIcon {
    param(
        [System.Windows.Window]$Window,
        [string]$IconPath
    )
    
    try {
        # Set unique AppUserModelID for this app
        [WindowsAPI]::SetCurrentProcessExplicitAppUserModelID("ZapretGUI.App")
        
        # Get window handle
        $helper = New-Object System.Windows.Interop.WindowInteropHelper($Window)
        $hwnd = $helper.EnsureHandle()
        
        # Load and set icon via WM_SETICON
        $icon = New-Object System.Drawing.Icon($IconPath)
        [WindowsAPI]::SendMessage($hwnd, [WindowsAPI]::WM_SETICON, [IntPtr]1, $icon.Handle) | Out-Null
        [WindowsAPI]::SendMessage($hwnd, [WindowsAPI]::WM_SETICON, [IntPtr]0, $icon.Handle) | Out-Null
        
        # Also set WPF icon
        $uri = New-Object System.Uri($IconPath, [System.UriKind]::Absolute)
        $Window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create($uri)
        
        return $true
    }
    catch {
        return $false
    }
}
