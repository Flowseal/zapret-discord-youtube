# Zapret (обход блокировки Discord'а и Youtube'а)
> [!CAUTION]  
> В сети появились правдоподобные копии аккаунтов, которые распространяют вредоносное ПО под видом Zapret. \
> Отличить оригинал от фейка вы всегда можете по количеству [⭐ звёзд](https://github.com/Flowseal/zapret-discord-youtube/stargazers) (в правом верхнем углу) у репозитория.

## Guides
### Windows
> [!IMPORTANT]  
> Если всё еще не скачан, то скачайте последний [релиз](https://github.com/Flowseal/zapret-discord-youtube/releases), разархивируйте в отдельную папку.

Запустите **от имени администратора** то, что вам нужно:
- **`discord.bat`** - запустить обход дискорда.
- **`general.bat`** - запустить обход дискорда и ютуба.
###
- **`service_discord.bat`** - запустить обход дискорда и поставить на автозапуск (в сервисах).
- **`service_general.bat`** - запустить обход дискорда и ютуба и поставить на автозапуск (в сервисах).
###
- **`service_goodbye_discord.bat`** - запустить, если вы используете **СЕРВИС goodbyedpi**, и хотите, чтобы zapret обходил **только discord**.
  * **ВНИМАНИЕ**: Запускать ПОСЛЕ создания сервиса goodbyedpi. Первый раз goodbyedpi может вылететь - просто перезапустите устройство!
###
- **`service_remove.bat`** - остановить и удалить сервисы выше

## Решение проблем

- Проверьте, запускаете ли вы файлы от **ИМЕНИ АДМИНИСТРАТОРА**
- Не запускаются bat файлы? Попробуйте запустить **`service_remove.bat`** от **ИМЕНИ АДМИНИСТРАТОРА**
  * Также отключите программы, которые могут мешать созданию сервиса *(Антивирусы, клинеры с доп. защитой)*.
- <p style="text-align: left;">
    <img src="https://cdn-icons-png.flaticon.com/16/3670/3670147.png" alt="discord" style="vertical-align: middle;"/>
    Не работает <strong>Youtube</strong>? Попробуйте найти ответ здесь - 
    <a href="https://github.com/Flowseal/zapret-discord-youtube/discussions/251">Обсуждение YouTube</a>
  </p>
- <p style="text-align: left;">
    <img src="https://cdn-icons-png.flaticon.com/16/906/906361.png" alt="discord" style="vertical-align: middle;"/>
    Не работает <strong>Discord</strong>? Попробуйте найти ответ здесь - 
    <a href="https://github.com/Flowseal/zapret-discord-youtube/discussions/252">Обсуждение Discord</a>
  </p>
##
- Не работает вместе с **VPN**? Отключите функцию **TUN** (Tunneling) в настройках VPN.
- Не работает **`service_goodbye_discord`**? Удостовертесь, что сервис goodbyedpi запущен и имеет название GoodbyeDPI. После снова запустите `service_goodbye_discord.bat` и перезапустите устройство.
- Попробуйте обновить бинарники с оригинального репозитория.

### Остановка и удаление обхода
Для этого запустите **`service_remove.bat`**.
- Если WinDivert так и не удалился, узнайте его название с помощью команды `driverquery | find "Divert"` в cmd, а затем удалите данными командами (заместо WinDivert введите название, которые вы узнали):
```
sc stop WinDivert
sc delete WinDivert
```

### Добавление дополнительных адресов заблокированных сайтов 
- Список можно дополнить используя `list-general.txt` (для файлов `general`) и в список `list-discord` (для файлов `discord`).
> [!IMPORTANT]  
> После добавления сервис нужно перезапустить.

## Linux
В оригинальном репозитории [zapret](https://github.com/bol-van/zapret/) имеется достаточно информации для того, чтобы начать пользоваться обходом блокировок, но и стоит понимать, что нажатием одной кнопки ничего не заработает. \
Достаточно следовать следующим инструкциям и всё внимательно читать:
- [zapret/docs/quick_start.txt](https://github.com/bol-van/zapret/blob/master/docs/quick_start.txt)
- [zapret/docs/readme.txt](https://github.com/bol-van/zapret/blob/master/docs/readme.txt)
  * https://github.com/Flowseal/zapret-discord-youtube/issues/7
> [!WARNING]
> Если вы открываете Issue *(в этом репозитории)* с проблемой в использовании на **Linux**, то, как бы это не звучало, это ошибка. Все вопросы по работе на Linux нужно открывать в **[ОРИГИНАЛЬНОМ](https://github.com/bol-van/zapret/)** репозитории. Следовательно, задавайте вопросы [тут](https://github.com/bol-van/zapret/issues/).

## Support

If you like the project, leave a :star: (top right) and become a [stargazer](https://github.com/Flowseal/zapret-discord-youtube/stargazers)!

[![Stargazers repo roster for @Flowseal/zapret-discord-youtube](https://reporoster.com/stars/dark/Flowseal/zapret-discord-youtube)](https://github.com/Flowseal/zapret-discord-youtube/stargazers)

## Credits & Contributors
<p align="left">
  <a href="https://github.com/Flowseal/zapret-discord-youtube/graphs/contributors">
    <img src="https://contrib.rocks/image?repo=Flowseal/zapret-discord-youtube" />
  </a>
</p>

* Many thanks to [bol-van](https://github.com/bol-van/), creator of original [zapret](https://github.com/bol-van/zapret/) repository.
