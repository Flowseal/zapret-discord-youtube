# Zapret GUI - Theme Definition

$script:Theme = @{
    # Main colors
    Background = "#000000"
    Surface = "#0a0a0a"
    SurfaceLight = "#111111"
    Border = "#1a1a1a"
    BorderLight = "#222222"
    
    # Text colors
    TextPrimary = "#ffffff"
    TextSecondary = "#888888"
    TextMuted = "#555555"
    TextDark = "#333333"
    
    # Accent colors
    Accent = "#ffffff"
    AccentHover = "#e0e0e0"
    AccentText = "#000000"
    
    # Status colors
    Success = "#4ade80"
    Warning = "#fbbf24"
    Error = "#ef4444"
    
    # Window
    CornerRadius = 16
    ButtonRadius = 6
    SectionRadius = 12
}

function Format-StatusText {
    param([string]$Status)
    
    switch ($Status) {
        "Running"      { return "RUNNING" }
        "Active"       { return "ACTIVE" }
        "Stopped"      { return "STOPPED" }
        "Inactive"     { return "INACTIVE" }
        "NotInstalled" { return "NOT INSTALLED" }
        default        { return "UNKNOWN" }
    }
}

function Get-StatusColor {
    param([string]$Status)
    
    switch ($Status) {
        "Running"      { return $script:Theme.Success }
        "Active"       { return $script:Theme.Success }
        "Stopped"      { return $script:Theme.Warning }
        "Inactive"     { return $script:Theme.TextMuted }
        "NotInstalled" { return $script:Theme.TextMuted }
        default        { return $script:Theme.TextMuted }
    }
}
