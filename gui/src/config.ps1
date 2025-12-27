# Zapret GUI - Configuration
# Version and settings

$script:Config = @{
    Version = "1.9.1"
    AppName = "Zapret GUI"
    
    # GitHub URLs
    GitHubVersionUrl = "https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/main/.service/version.txt"
    GitHubReleaseUrl = "https://github.com/Flowseal/zapret-discord-youtube/releases/tag/"
    GitHubDownloadUrl = "https://github.com/Flowseal/zapret-discord-youtube/releases/latest/download/zapret-discord-youtube-"
    
    # Designer credits
    DesignerName = "ibuildrun"
    DesignerUrl = "https://github.com/ibuildrun"
}

# Get root directory (parent of gui/src folder)
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:RootDir = Split-Path -Parent (Split-Path -Parent $scriptDir)
$script:BinDir = Join-Path $script:RootDir "bin"
$script:ListsDir = Join-Path $script:RootDir "lists"
$script:UtilsDir = Join-Path $script:RootDir "utils"
