<div align="center">

# codeDPI

**All-in-One Windows DPI bypass + Cloudflare WARP + PAC routing — в одном маленьком окне.**

</div>

---

## Что это

Один кликабельный `.bat` поднимает систему обхода блокировок для Windows. Под капотом — два разных слоя, потому что блокировки в России двух разных типов:

| Тип блокировки | Кто блокирует | Чем codeDPI обходит |
|---|---|---|
| **DPI** (TLS SNI / QUIC) — Discord, YouTube, Telegram-web, Meta, X, LinkedIn, Signal, TikTok, Reddit, Patreon, Notion-DPI, Imgur, Spotify-web | Российский провайдер | `winws.exe` десинхронизирует первые пакеты соединения через драйвер `WinDivert` — DPI не успевает прочитать SNI |
| **Гео** (server-side) — ChatGPT, Claude, Gemini, Cursor, Copilot, Spotify-geo, Notion-geo | Сам сервис, по IP-геолокации | Через **Cloudflare WARP** (бесплатный SOCKS5 на `127.0.0.1:40000`) только для выбранных доменов — остальной трафик идёт обычным путём |

Гео-роутинг работает через локальный PAC-файл, который раздаётся встроенным HTTP-сервером на `http://127.0.0.1:27289/launcher.pac`. Браузеры (Chrome / Edge / Opera / Brave) подхватывают его автоматически через `HKCU\...\AutoConfigURL`. Firefox — отдельная вставка URL в `about:preferences → Network Settings`.

## Как запустить

1. **Скачай репо:** `Code → Download ZIP` или `git clone https://github.com/defomok-max/codeDPI.git`.
2. **Распакуй** в путь без кириллицы и пробелов.
3. **Двойной клик [`start.bat`](./start.bat)** — попросит UAC и поднимет маленькое окно с 4 кнопками:

   - **▶  Запустить** — DPI bypass + WARP + PAC одной командой.
   - **■  Остановить** — гасит всё.
   - **⚙  Настройки** — открывает полный WPF GUI: чекбоксы каждого сервиса, выбор стратегии (`ALT*`/`FAKE TLS AUTO*`/`SIMPLE FAKE*`), ручное управление WARP, импорт WireGuard-конфига, системный прокси и т. д.
   - **✓  Тест связи** — за ~10 сек прогоняет smoke-test: PAC server / WARP / DPI (`youtube.com/generate_204`) / Geo (`chatgpt.com` через WARP).

   Сверху — точка статуса (зелёная / жёлтая / серая) и одна строка с деталями вида `winws · warp · pac:27289`.

Альтернативные точки входа:

- `start.bat gui` — сразу полный WPF GUI (вместо chooser-а).
- `start.bat cli` — консольное TUI (на случай если WPF/PowerShell GUI не нужен).
- `launcher.bat` — то же самое, что `start.bat`, для обратной совместимости.

### Если что-то пошло не так

Если окно мигнуло и закрылось — раньше так и было задумано (cmd выходил вместе со скриптом), теперь нет: при любой ошибке окно остаётся открытым с текстом ошибки и стэк-трейсом, а копия пишется в `launcher.log` в корне репо. Пришлите этот файл в issue, если launcher падает у вас.

## Стратегии DPI

В `bin/` лежат `winws.exe` + `WinDivert64.sys` от [bol-van/zapret-win-bundle](https://github.com/bol-van/zapret-win-bundle). В корне репо — набор `general*.bat`, каждый — это **одна стратегия** (фиксированный набор флагов `winws.exe`). Провайдеры разные, поэтому стратегии разные:

- `general.bat`, `general (ALT).bat` ... `general (ALT11).bat`
- `general (FAKE TLS AUTO).bat` ... `(FAKE TLS AUTO ALT3).bat`
- `general (SIMPLE FAKE).bat`, `(SIMPLE FAKE ALT).bat`, `(SIMPLE FAKE ALT2).bat`

В chooser-е при первом запуске берётся `general.bat`. Если у тебя зеленится статус, но конкретный сервис всё равно не открывается — открой *Настройки* и переключи стратегию в дропдауне. Та, что работает у одного провайдера, может не работать у другого.

## Поддерживаемые сервисы

### DPI (zapret) — toggle в *Настройках*

YouTube, Discord, Cloudflare, Twitch chat, Meta (Instagram / Facebook / Threads / WhatsApp web), Telegram-web + CDN, X / Twitter, LinkedIn, Signal, TikTok, Reddit, Patreon, Notion (DPI-вариант), Imgur, Spotify (web), News (BBC/DW/Meduza/RFE/RL — выкл. по умолчанию).

Хочется свои домены — добавь в [`lists/list-custom.txt`](./lists/list-custom.txt) (по одному на строку).

### Geo (через WARP+PAC) — toggle в *Настройках*

ChatGPT / OpenAI, Claude / Anthropic, Google Gemini / AI Studio, Cursor, GitHub Copilot, Spotify (geo), Notion (geo). Свой список — `lists/geo-custom.txt`.

## Чего codeDPI **не** сделает

- **Telegram Desktop** — он ходит по MTProto на нестандартных портах, DPI-обход не поможет. Используй [Flowseal/tg-ws-proxy](https://github.com/Flowseal/tg-ws-proxy). codeDPI покрывает только web-версию + CDN.
- **Netflix / Disney+ / банки** — они палят датацентровые IP Cloudflare WARP и блокируют его не хуже. Нужен полноценный VPN с residential IP — кладёшь свой WireGuard-конфиг в раздел *Custom VPN / Proxy* в полном GUI.
- **Discord-desktop / Steam / любые не-браузерные приложения** — PAC они не читают. Selective routing для них не работает; либо ставь WARP в `mode warp` (full tunnel, но тогда сломаются банки и Госуслуги), либо вешай прокси системно.

## Файлы

| Что | Зачем |
|---|---|
| [`start.bat`](./start.bat) | Главная точка входа — открывает chooser. |
| [`launcher.bat`](./launcher.bat) | Алиас `start.bat` для обратной совместимости. |
| [`utils/launcher.chooser.ps1`](./utils/launcher.chooser.ps1) | Минимальный WPF-чекбокс на 4 кнопки. |
| [`utils/launcher.gui.ps1`](./utils/launcher.gui.ps1) | Полный WPF GUI (все сервисы, стратегия, WARP, кастомный VPN). |
| [`utils/launcher.ps1`](./utils/launcher.ps1) | Консольное TUI (для тех, кому WPF не нужен). |
| [`utils/launcher.lib.ps1`](./utils/launcher.lib.ps1) | Общая логика. CLI и GUI вызывают её одинаково. |
| [`utils/launcher.pacserver.ps1`](./utils/launcher.pacserver.ps1) | HTTP-сервер для отдачи PAC по `http://127.0.0.1:27289/launcher.pac`. |
| `lists/list-*.txt` | Списки доменов под DPI-обход. |
| `lists/geo-*.txt` | Списки доменов, для которых нужен другой выходной IP. |
| `lists/list-custom.txt`, `lists/geo-custom.txt` | Твои собственные домены. |
| `general*.bat` | Стратегии `winws.exe` (флаги десинхронизации). От апстрима. |
| `bin/` | `winws.exe` + `WinDivert64.sys` + готовые TLS/QUIC-фейк-пакеты. От апстрима. |
| `service.bat` | Установка `winws` как Windows-службу + диагностика. От апстрима. |
| `launcher.conf` | Сохранённое состояние GUI (чекбоксы, стратегия). В репо не попадает. |

## Конфигурация

`launcher.conf` (создаётся при первом запуске GUI) — `key=value`, UTF-8 без BOM. Ключи, которые могут быть полезны вручную:

```
strategy=general (ALT3).bat   # имя выбранного general*.bat
warp_autostart=1               # 0/1 — поднимать WARP вместе с bypass
geo_routing=1                  # 0/1 — включить PAC routing для гео-доменов
pac_port=27289                 # порт локального PAC HTTP-сервера
service_meta=1                 # 0/1 — DPI-обход для Meta (аналогично для других сервисов)
geo_openai=1                   # 0/1 — gео-роутинг для OpenAI/ChatGPT
```

Менять ключи можно прямо в Блокноте — chooser перечитывает конфиг при открытии *Настроек*.

## WinDivert и антивирусы

`WinDivert64.sys` — kernel-driver для перехвата трафика (аналог `iptables`/`NFQUEUE` в Linux, которых на Windows нет). Антивирусы иногда помечают его как `RiskTool.WinDivert` — это **не вирус**, просто инструмент двойного назначения; драйвер подписан Microsoft-совместимой подписью для загрузки в 64-битное ядро. В случае ругани добавь папку `bin/` в исключения антивируса (или выключи детект PUA, если разбираешься).

## Что внутри. Откуда что взято

codeDPI = launcher + апстримные движки.

- **DPI-обход:** [bol-van/zapret](https://github.com/bol-van/zapret) — кросс-платформенный механизм десинхронизации, изначально под Linux/iptables. Windows-сборка — [bol-van/zapret-win-bundle](https://github.com/bol-van/zapret-win-bundle): `winws.exe` + `WinDivert`. Бинарники в `bin/` идут оттуда.
- **Стратегии (`general*.bat`):** [Flowseal/zapret-discord-youtube](https://github.com/Flowseal/zapret-discord-youtube) — апстримная подборка флагов `winws.exe` под российских провайдеров. codeDPI — форк этого репо с добавленным launcher-ом и поддержкой большего числа сервисов + WARP-интеграцией.
- **Cloudflare WARP** — бесплатный, [`1.1.1.1` от Cloudflare](https://1.1.1.1/). Используется здесь не как VPN, а как локальный SOCKS5 для гео-роутинга.

Поддержать оригинального разработчика zapret можно [тут](https://github.com/bol-van/zapret?tab=readme-ov-file#%D0%BF%D0%BE%D0%B4%D0%B4%D0%B5%D1%80%D0%B6%D0%B0%D1%82%D1%8C-%D1%80%D0%B0%D0%B7%D1%80%D0%B0%D0%B1%D0%BE%D1%82%D1%87%D0%B8%D0%BA%D0%B0).

## Лицензия

[MIT](./LICENSE.txt) — наследуется от апстрима. Бинарники `bin/` — от bol-van, под их соответствующими лицензиями (см. их репо).
