# targets.txt - endpoint list for zapret.ps1 tests
#
# Format:
#   KeyName = "https://host..."   -> Runs HTTP/TLS checks + ping
#   KeyName = "PING:1.2.3.4"       -> Ping only
#
# Keys must be a single word (letters/digits/underscore), because the
# script parses them as simple identifiers. You can add or remove lines.

### Discord
DiscordMain           = "https://discord.com"
DiscordGateway        = "https://gateway.discord.gg"
DiscordCDN            = "https://cdn.discordapp.com"
DiscordUpdates        = "https://updates.discord.com"

### YouTube
YouTubeWeb            = "https://www.youtube.com"
YouTubeShort          = "https://youtu.be"
YouTubeImage          = "https://i.ytimg.com"
YouTubeVideoRedirect  = "https://redirector.googlevideo.com"

### Google
GoogleMain            = "https://www.google.com"
GoogleGstatic         = "https://www.gstatic.com"

### Cloudflare
CloudflareWeb         = "https://www.cloudflare.com"
CloudflareCDN         = "https://cdnjs.cloudflare.com"

### Public DNS (PING-only)
CloudflareDNS1111     = "PING:1.1.1.1"
CloudflareDNS1001     = "PING:1.0.0.1"
GoogleDNS8888         = "PING:8.8.8.8"
GoogleDNS8844         = "PING:8.8.4.4"
Quad9DNS9999          = "PING:9.9.9.9"
