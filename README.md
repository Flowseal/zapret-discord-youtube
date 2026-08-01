<div align="center">

# <img src="https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/discord.svg" height=28 /> <a href="https://github.com/Flowseal/">Flowseal</a><a href="https://github.com/Flowseal/zapret-discord-youtube">/zapret-discord-youtube</a> <img src="https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/youtube.svg" height=28 />

Альтернатива [оффициальной сборке zapret для Windows](https://github.com/bol-van/zapret-win-bundle/tree/master/zapret-winws)
</div>

> [!CAUTION]
>
> ### Фейки
> Этот [GitHub репозиторий](https://github.com/Flowseal/zapret-discord-youtube) **единственный официальный источник** сборки zapret от Flowseal.
>

> [!IMPORTANT]
>
> ### WinDivert
> 
> [WinDivert](https://reqrypt.org/windivert.html) - это замена [NetFilter](https://ru.wikipedia.org/wiki/Netfilter), необходимая для работы с zapret в Windows.
> 
> Антивирус может ругаться на WinDivert со сигнатурами по типу `Not-a-virus:RiskTool.Multi.WinDivert`. Добавляйте исключения / отключайте реакции на PUP/PUA / полностью отключайте антивирус.
>

> [!WARNING]
> Ваш интернет-провайдер может заниматься [DNS Hijacking](https://ru.wikipedia.org/wiki/DNS_hijacking)'ом. Рекомендуется включить [DNS-over-HTTPS](https://ru.wikipedia.org/wiki/DNS_%D0%BF%D0%BE%D0%B2%D0%B5%D1%80%D1%85_HTTPS) / [DNS-over-TLS](https://ru.wikipedia.org/wiki/DNS_%D0%BF%D0%BE%D0%B2%D0%B5%D1%80%D1%85_TLS) в параметрах браузера/Windows/роутера:
>
>   <div align="center">
>    <a href="https://www.comss.ru/page.php?id=6421"><img src="https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/chrome.svg" height="128" /></a>&nbsp;&nbsp;&nbsp;&nbsp;
>    <a href="https://support.mozilla.org/ru/kb/dns-cherez-https-v-firefox"><img src="https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/firefox.svg" height="128" /></a>&nbsp;&nbsp;&nbsp;&nbsp;
>    <a href="https://remontka.pro/dns-over-https-windows-11/"><img src="https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/windows-11.png" height="128" /></a>&nbsp;&nbsp;&nbsp;&nbsp;
>    <a href="https://support.keenetic.com/hero/kn-1011/en/25049-dot-and-doh-proxy-servers-for-dns-requests-encryption.html"><img src="https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/keenetic-alt.svg" height="128" /></a>
</div>

## 🚀 Установка

Загрузите [последний релиз](https://github.com/Flowseal/zapret-discord-youtube/releases/latest) (zip/rar) распакуйте по пути, **несодержащем пробелы/кириллицу/спец. символы.** Запускайте файлы стратегий (`general (***).bat`) от имени администратора и проверяйте доступность сервисов/ресурсов, как нашли подходящую, запустите `service.bat` > `Install Service` > выберите стратегию, теперь winws будет запускаться автоматически как служба Windows.

>[!NOTE]
>Права администратора необходимы для загрузки драйвера `WinDivert` в ядро Windows

## ⚙️ Описания batch-файлов

- **`general (***)`** - файлы стратегий для ручного запуска `winws` в окне 

- [**`service`**](./service.bat) - управление сборкой с опциями меню:
  - `Install Service` - установка служб
  - `Remove Services` - удаление служб
  - `Check Status` - проверка статуса служб
  - `Game Filter` - фильтр на порты 1023-65535 (UDP и TCP)
  - `IPSet Filter` - фильтр на адреса из `lists/ipset-all.txt`:
       - `none` - фильтр отключен
       - `loaded` - фильтр только на адреса в `lists/ipset-all.txt`
       - `any` - фильтр на любой IP (не рекомендуется)
  - `Auto-Update Check` - автоматическая проверка на обновления
  - `Replace active fakes` - заменить указанный для fake бинарный файл на другой в директории `bin`
  - `Update IPSet List` - обновление списка `lists/ipset-all.txt` актуальным из репозитория
  - `Update Hosts File` - обновление файла hosts 
  - `Check for Updates` - проверка на обновления
  - `Run Diagnostics` - диагностика распространённых проблем, также можно очистить кэш <img src="https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/discord.svg" height=14 /> Discord
  - `Run Tests` - запуск утилиты для проверки стратегии на работоспособность:
    - `Standard tests` - проверка сайтов из `utils/targets.txt`
    - `DPI checkers` - проверка доступа к серверам облачных провайдеров (Cloudflare, Amazon и др.)

## 📝 Добавление адресов прочих ресурсов

> [!IMPORTANT]
> Файлы `*-user.txt` создаются автоматически при первом запуске `winws` или `service.bat`

Список адресов для фильтров можно расширить, добавляя их в файлы из директории `lists`:

- `list-general-user.txt` - домены (поддомены автоматически учитываются)
- `list-exclude-user.txt` - исключенные домены
- `ipset-all.txt` - IP-адреса и подсети
- `ipset-exclude-user.txt` -  исключенные IP-адреса и подсети
 
## ✅ Распространённые проблемы и их решения

### `winws` вручную / служба не запускается

- Запустите `service.bat` > `Remove Services`
- Выключите любой другой софт, модифицирующий ваш интернет-трафик (например, VPN, GoodbyeDPI, прочие сборки zapret)

>[!IMPORTANT]
>Любой другой софт, использующий WinDivert мог оставить его службу. Имя службы может быть вообще каким угодно.
>
>Если вы нашли имя службы, используйте командную строку Windows от имени администратора и введите следующие команды:
>```cmd
>sc stop <название службы>
>sc delete <название службы>
>```

### После запуска некоторые ресурсы остаются недоступными 

- Убедитесь, что адрес ресурса записан в списках доменов или IP в директории `lists`
- Запустите `service.bat` > `Run Diagnostics` и исправьте проблемы, если имеются
- Пробуйте другие стратегии (**`ALT`**/**`FAKE`** и другие)

> [!IMPORTANT]
> Стратегии со временем могут переставать работать из-за развития DPI систем ТСПУ.
> 
> **Помните: это не проблема сборки**, если ни одна из представленных в сборке стратегий **у Вас** не работает, ищите другую сборку или создавайте свою стратегию сами по [документации к winws](https://github.com/bol-van/zapret/blob/master/docs/readme.md#nfqws) (nfqws).

### После запуска ресурсы становятся недоступными

Проверьте, что состояние `Game Filter` - `disabled`, а `IPSet Filter` - `none`. Эти фильтры могут влиять на работу доступных ресурсов.

### Не работает <img src="https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/telegram.svg" height=18 /> Telegram Web или бесконечное "Подключение" к голосовому чату <img src="https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/discord.svg" height=16 /> Discord 
Запустите `service.bat` > `Update hosts file`.
Eсли ваш hosts будет неактуальным, то Вам будет предложено обновить его самостоятельно:  
  - Скопируйте весь текст из открывшегося блокнота
  - Откройте файл `hosts` в появившейся папке с помощью текстового редактора, открытого от имени администратора
  - Добавьте в конец файла `hosts` то, что скопировали (или замените, если до этого Вы уже добавляли подобное)
  - Сохраните и перепроверьте подключение. Если не работает - убедитесь, что файл `hosts` действительно сохранился.

### Не работают игры
- Запустите `service.bat` > `Update IPSet List` и включите `Game Filter`
- Проверьте [дискуссии](https://github.com/Flowseal/zapret-discord-youtube/discussions) на наличие проблемы у других игроков/создайте свою и ждите помощи
- Переключите `IPSetFilter` в состояние `any`

> [!IMPORTANT]
> При переключении `IPSetFilter` в состояние `any` могут появится проблемы с открытием многих сайтов. Рекомендуется найти список IP адресов, используемых игрой, и добавить их в `lists/ipset-all.txt`

### Цифровая подпись драйвера `WinDivert` для Windows 7

>[!NOTE]
> Сборка содержит драйвер подписанный для новых версий Windows
>
> Система подписи драйверов была изменена со времен Windows 7
>

Замените файлы WinDivert (`WinDivert.dll` и `WinDivert64.sys`) в директории [`bin`](./bin) на одноименные из [zapret-win-bundle/win7](https://github.com/bol-van/zapret-win-bundle/tree/master/win7)

### Античиты ругаются на WinDivert

Возможное решение: https://github.com/bol-van/zapret-win-bundle/tree/master/windivert-hide

### Не нашли решения своей проблемы?

Создайте [Issue](https://github.com/Flowseal/zapret-discord-youtube/issues)


## 📈 Поддержка проекта

Вы можете поддержать проект, поставив :star: этому репозиторию (сверху справа этой страницы)

> [!TIP]
> ### 💸 Материальная поддержка
>
> [basil@reqrypt](https://reqrypt.org/donate.html) (автор WinDivert)
> 
> [bol-van](https://github.com/bol-van/zapret#%D0%BF%D0%BE%D0%B4%D0%B4%D0%B5%D1%80%D0%B6%D0%B0%D1%82%D1%8C-%D1%80%D0%B0%D0%B7%D1%80%D0%B0%D0%B1%D0%BE%D1%82%D1%87%D0%B8%D0%BA%D0%B0) (автор zapret)
> 
> [Flowseal](https://github.com/Flowseal/tg-ws-proxy#-%D0%BF%D0%BE%D0%B4%D0%B4%D0%B5%D1%80%D0%B6%D0%B0%D1%82%D1%8C-%D0%BC%D0%B5%D0%BD%D1%8F) (автор этой сборки)

## ⚖️ Лицензирование

[WinDivert](https://reqrypt.org/windivert.html) - [GNU GPL 3](https://github.com/basil00/WinDivert/blob/master/LICENSE) /
[zapret](https://github.com/bol-van/zapret) - [MIT](https://github.com/bol-van/zapret/blob/master/docs/LICENSE.txt) /
[сборка](https://github.com/Flowseal/zapret-discord-youtube) - [MIT](./LICENSE.txt)

## ❤️ Благодарность участникам проекта

[![Contributors](https://contrib.rocks/image?repo=Flowseal/zapret-discord-youtube)](https://github.com/Flowseal/zapret-discord-youtube/graphs/contributors)

<div align="center">

## ❤️ Отдельная благодарность разработчику и создателю проекта [zapret](https://github.com/bol-van/zapret) ❤️
[bol-van](https://github.com/bol-van)
