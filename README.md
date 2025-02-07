# Zapret для обхода блокировок [Discord](https://discord.com) и [Youtube](https://youtube.com)

## Описание

Это *некоммерческая*, более *user-friendly* сборка [Zapret](https://github.com/bol-van/zapret). Сборка использует бинарники [оригинального репозитория](https://github.com/bol-van/zapret), проверить которые вы можете с помощью хэшей/контрольных сумм.

> [!WARNING]
> Многие антивирусные программы в данный момент жалуются на **`HackTool/RiskTool`** и **`WinDivert`** - это нормальное поведение, так как программа изменяет сетевые пакеты.
>
> Решения, если для вас это проблема:
>
> - Самостоятельно собрать бинарники из открытых исходников из [оригинального репозитория](https://github.com/bol-van/zapret)
> - Довериться собранным
> - Не использовать эту сборку

## Использование

### Windows

> [!IMPORTANT]
> Рекомендуется загружать [последний релиз](https://github.com/Flowseal/zapret-discord-youtube/releases/latest) (zip/rar)
> и распаковывать по пути, который не содержит кириллицы, пробелов и спец. символов.

Запустите **от имени администратора** (ПКМ по выбранному файлу > "Запуск от имени администратора") выбранный bat-файл:

- [**`discord.bat`**](./discord.bat) - запуск обхода блокировки [Discord](https://discord.com/)

- [**`general.bat`**](./general.bat) - запуск обхода блокировок [Discord](https://discord.com/) и [YouTube](https://youtube.com/)

  * Если обход не работает, проверьте стратегии **`ALT`**

  * Если обход не работает со всеми стратегиямм **`ALT`**, проверьте стратегии **`МГТС`**

- [**`service_install.bat`**](./service_install.bat) - установка обхода на автозапуск (как служба Windows), можно выбрать любую стратегию (стратегия **НЕ** должна начинаться со слова `service`)

- [**`service_remove.bat`**](./service_remove.bat) - остановка и удаление службы обхода

- [**`service_status.bat`**](./service_status.bat) - проверка состояния службы обхода

- [**`check_updates.bat`**](./check_updates.bat) - проверка обновлений

> [!Important]  
> Стратегии блокировок могут изменятся со временем. Следовательно, одна стратегия для Zapret не всегда может работать, даже если до этого она работала какое-то время.  В репозитории представлены множество различных стратегий для обхода. Стратегия может работать какое-то время, но если меняется способ блокировки или обнаружения обхода блокировки, то она не сработает или перестанет работать та, которую вы использовали. Поэтому сидеть только на одной и пытаться запускать её каждый раз если она перестала работать - нет смысла.  Если ни одна из них вам не помогает, то вам необходимо создать новую, взяв за основу одну из представленных здесь и изменить её параметры. Информация из оригинального репозитория про параметры стратегий - https://github.com/bol-van/zapret/blob/master/docs/readme.md#nfqws

### Linux

Данная сборка является решением для **Windows**. Информацию для использования на ОС Linux вы можете найти в документации оригинального [Zapret](https://github.com/bol-van/zapret) - [Быстрая настройка Linux/OpenWrt](https://github.com/bol-van/zapret/blob/master/docs/quick_start.md).

Также вы можете найти "порт" от энтузиаста [Sergeydigl3](https://github.com/Sergeydigl3): [#697](https://github.com/Flowseal/zapret-discord-youtube/issues/697)

> [!WARNING]
> Следовательно, не открывайте проблему (issue), связанную с использованием на ОС Linux, в этом репозитории!

## Возможные проблемы и их решения

### bat-файлы запускаются, но ресурс(-ы) не работает(-ют)

> [!IMPORTANT]
> **Zapret не имеет функционала VPN!**
> Следовательно, если ресурс блокирует доступ с вашего IP, Zapret с этим не поможет.

**Решения:**

- Запуск от **имени администратора** (ПКМ по выбранному файлу > "Запуск от имени администратора")

- При неработе [**YouTube**](https://youtube.com) ![YouTube logo](https://cdn-icons-png.flaticon.com/16/3670/3670147.png) - см. [Обход для YouTube](https://github.com/Flowseal/zapret-discord-youtube/discussions/251)

- При неработе [**Discord**](https://discord.com) ![Discord logo](https://cdn-icons-png.flaticon.com/16/906/906361.png) - см. [Обход для Discord](https://github.com/Flowseal/zapret-discord-youtube/discussions/252)

- Обновите бинарники с [оригинального репозитория](https://github.com/bol-van/zapret)

- Обратитесь к документации по использованию из оригинального репозитория [**тут**](https://github.com/bol-van/zapret/blob/master/docs/quick_start_windows.md)

- См. [#765](https://github.com/Flowseal/zapret-discord-youtube/issues/765)

### bat-файлы не запускаются

**Решения:**

- См. [#522](https://github.com/Flowseal/zapret-discord-youtube/issues/522)

### Не работает вместе с VPN

**Решения:**

- Отключите функцию **TUN** (Tunneling) в настройках вашего VPN

### Требуется цифровая подпись драйвера WinDivert (Windows 7)

**Решения:**

- См. [#1319](https://github.com/Flowseal/zapret-discord-youtube/issues/1319#issuecomment-2613979041)

### При удалении с помощью [**`service_remove.bat`**](./service_remove.bat), WinDivert остается в службах

**Решение:**

1. Узнайте название службы с помощью команды, в командной строке Windows (Win+R, `cmd`):

```cmd
driverquery | find "Divert"
```

2. Удалите службу командами (вместо `WinDivert` введите название, которые вы узнали в предыдущем шаге):

```cmd
sc stop WinDivert

sc delete WinDivert
```

### Не нашли своей проблемы

* Создайте её [тут](https://github.com/Flowseal/zapret-discord-youtube/issues)

## Добавление адресов прочих заблокированных ресурсов

Список блокирующихся адресов для обхода можно расширить, добавляя их в [`list-general.txt`](./list-general.txt) (для файлов `general... .bat`) или в [`list-discord.txt`](./list-discord.txt) (для файла [`discord.bat`](./discord.bat))

> [!IMPORTANT]  
> После обновления списка адресов сервис необходимо перезапустить.

## Поддержка проекта

Вы можете поддержать сборку, поставив :star: этому репозиторию (сверху справа этой страницы)!

Также, вы можете материально поддержать разработчика оригинала [тут](https://github.com/bol-van/zapret/issues/590#issuecomment-2408866758).

<a href="https://star-history.com/#Flowseal/zapret-discord-youtube&Date">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=Flowseal/zapret-discord-youtube&type=Date&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=Flowseal/zapret-discord-youtube&type=Date" />
   <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=Flowseal/zapret-discord-youtube&type=Date" />
 </picture>
</a>

## Лицензирование

Этот проект распространяется на условиях лицензии [MIT](https://github.com/Flowseal/zapret-discord-youtube/blob/main/LICENSE.txt).  

## Благодарность участникам проекта

[![Contributors](https://contrib.rocks/image?repo=Flowseal/zapret-discord-youtube)](https://github.com/Flowseal/zapret-discord-youtube/graphs/contributors)

Отдельные благодарности:
- разработчику оригинального [Zapret](https://github.com/bol-van/zapret) - [bol-van](https://github.com/bol-van)
- разработчику [порта для Linux](https://github.com/Flowseal/zapret-discord-youtube/discussions/697) - [Sergeydigl3](https://github.com/Sergeydigl3).
