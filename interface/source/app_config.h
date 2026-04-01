#pragma once

namespace AppConfig {

inline constexpr const char* kVersionUrl =				"https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/main/.service/version.txt";

inline constexpr const char* kUpdateArchiveUrl =		"https://github.com/Flowseal/zapret-discord-youtube/archive/refs/heads/main.zip";
inline constexpr const char* kTelegramProxyArchiveUrl = "https://github.com/Flowseal/tg-ws-proxy/archive/refs/heads/main.zip";
inline constexpr const char* kPythonManagerMsixUrl =	"https://www.python.org/ftp/python/pymanager/python-manager-26.1.msix";
inline constexpr const char* kZapretRepoExtractedFolderName = "zapret-discord-youtube-main";
inline constexpr const char* kTelegramRepoExtractedFolderName = "tg-ws-proxy-main";

inline constexpr const char* kDiscordProbeUrl =			"https://discord.com";
// Проверка доступа к CDN Discord (медиа); при истечении подписи URL заменить в конфиге.
inline constexpr const char* kDiscordMediaProbeUrl =
	"https://media.discordapp.net/attachments/1297990057986363554/1488929712180035715/820758430494359622.png?ex=69ce915a&is=69cd3fda&hm=82631aa9a588d2500f0b2e7549763d1756eeaf9a0350037ffb71c6007dd9945d&=&format=webp&quality=lossless";
inline constexpr const char* kYouTubeProbeUrl =			"https://i.ytimg.com";
inline constexpr const char* kTelegramProbeUrl =		"https://web.telegram.org";

} // namespace AppConfig
