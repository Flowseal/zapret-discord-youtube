# Zapret (обход блокировки Discord'а и Youtube'а)

## Guides
### Windows
> [!IMPORTANT]  
> Если всё еще не скачан, то скачайте последний [релиз](https://github.com/Flowseal/zapret-discord-youtube/releases), разархивируйте в отдельную папку.

Запустите **от имени администратора** то, что вам нужно:
- **`discord.bat`** - запустить обход дискорда.
- **`discord_youtube.bat`** - запустить обход дискорда и ютуба.
###
- **`service_discord.bat`** - запустить обход дискорда и поставить на автозапуск (в сервисах).
- **`service_discord_youtube.bat`** - запустить обход дискорда и ютуба и поставить на автозапуск (в сервисах).
###
> [!CAUTION]
> ВНИМАНИЕ: Запускать ПОСЛЕ создания сервиса goodbyedpi. Первый раз goodbyedpi может вылететь - просто перезапустите устройство!
- **`service_goodbye_discord.bat`** - запустить, если вы используете **СЕРВИС goodbyedpi**, и хотите, чтобы zapret обходил **только discord**.
###
- **`service_remove.bat`** - остановить и удалить сервисы выше

### Решение проблем
- Проверьте, запускаете ли вы файлы от имени администратора.
- Не работает сервис? Проверьте, чтобы в пути до файла **не было пробелов** и русских символов.
  * Также отключите программы, которые могут мешать созданию сервиса *(Антивирусы, клинеры с доп. защитой)*.
- Не работает вместе с VPN? Отключите функцию **TUN** (Tunneling) в настройках VPN.
- Не работает `service_goodbye_discord`? Удостовертесь, что сервис goodbyedpi запущен и имеет название GoodbyeDPI. После снова запустите `service_goodbye_discord.bat` и перезапустите устройство.
- Не прогружается видео на ютубе? Попробуйте поставить **`Kyber`** и **`QUIC`** в default (`chrome://flags/`).
  * Также в файле, который открываете, в строчке с `--filter-tcp=443`: попробуйте поменять `--dpi-desync-fooling=md5sig` на `--dpi-desync-fooling=badseq`.
  * https://github.com/Flowseal/zapret-discord-youtube/issues/46
- Попробуйте обновить бинарники с оригинального репозитория.
- Не работает **YouTube**? Попробуйте найти ответ здесь - https://github.com/Flowseal/zapret-discord-youtube/issues/90
- Не работает **Discord**? Попробуйте найти ответ здесь - https://github.com/Flowseal/zapret-discord-youtube/issues/92

### Хочу удалить, но остался файл WinDivert?
Для удаления оставшегося драйвера WinDivert, откройте cmd от имени администратора и пропишите следующее:
```
sc stop WinDivert
sc delete WinDivert
```
> [!NOTE]  
> Возможно, драйвер у вас будет записан по-другому. Для уточнения названия пропишите `driverquery | find "Divert"` в cmd.

### Добавление дополнительных адресов заблокированных сайтов: 
- Список можно дополнить используя `list-general.txt` (для `*discord_youtube`) и в список `list-discord` (для файлов без `youtube` в названии).
> [!IMPORTANT]  
> После добавления сервис нужно перезапустить.

## Linux
> [!WARNING]
> **ПЕРЕД НАЧАЛОМ**:  
> Описанный ниже способ не является универсальным. Если что-то не работает или не получается, не факт, что проблема с нашей стороны. Всё, что написано ниже, является еще более упрощенной версией итак упрощенной документации от [bol-van](https://github.com/bol-van/) в [zapret/docs/quick_start.txt](https://github.com/bol-van/zapret/blob/master/docs/quick_start.txt).
> Если вы открываете Issue *(в этом репозитории)* с проблемой в использовании на **Linux**, то, как бы это не звучало, это ошибка. Выше было сказано, что гайд написан основываясь на документацию **[ОРИГИНАЛЬНОГО](https://github.com/bol-van/zapret/)** репозитория, следовательно задавайте вопросы [там](https://github.com/bol-van/zapret/issues/).

0) Для начала необходимо клонировать репозиторий: `git clone --depth 1 https://github.com/bol-van/zapret`
   * На счет выбора расположения, то особо разницы не имеет, т.к. в ходе работы скрипт предложит вам переместить его в `/opt/`. Можете сделать это сразу, а можете не делать и позволить это сделать скрипту. Пример пути к файлу, для референса, что вы сделали всё правильно (если решили сами перенести файлы) - `/opt/zapret/install.bin.sh`
1) Убедитесь, что у вас отключены все средства обхода блокировок, в том числе и сам zapret. Если ранее использовали zapret, воспользуйтесь `uninstall_easy.sh`. Если вы работаете в виртуальной машине, необходимо использовать соединение с сетью в режиме `bridge`.
2) Запустите `install_bin.sh` и `install_prereq.sh` для установки необходимых пакетов и настройки "бинариков" для работы.
   * Вас могут спросить о типе фаервола (iptables/nftables) и использовании ipv6. Это нужно для установки правильных пакетов в ОС, чтобы не устанавливать лишнее.
3) Запустите `blockcheck.sh`. Если выводятся сообщения о подмене адресов, то первым делом нужно решить эту проблему, иначе ничего не будет работать. Подробнее про решение проблемы [тут](https://github.com/bol-van/zapret/blob/2cd6db3ba5ac2fa1494bed1c1903bc3531c76bc5/docs/quick_start.txt#L47).
4) По результатам проверки выберите рабочую стратегию обхода блокировок: `tpws` или `nfqws`, а также запомнить найденные стратегии.
5) Запустите `install_easy.sh`. Выберите `nfqws` или `tpws`, затем согласитесь на редактирование параметров. Откроется редактор, куда впишите найденные стратегии, не забудьте сохранить перед выходом из редактора, конечно же. Выбирайте правильный адаптер, если у вас их несколько из-за, например, Docker. На все остальные вопросы `install_easy.sh` отвечайте согласно выводимой аннонтации. Подробнее про детали установки [тут](https://github.com/bol-van/zapret/blob/2cd6db3ba5ac2fa1494bed1c1903bc3531c76bc5/docs/quick_start.txt#L115).
> Опять же: Это минимальная инструкция, чтобы соориентироваться с чего начать. Если что-то ломается или не получается, то идем и читаем все подробности и все детали. Подробности и полное техническое описание расписаны в [quick_start.txt](https://github.com/bol-van/zapret/blob/master/docs/quick_start.txt) и [readme.txt](https://github.com/bol-van/zapret/blob/master/docs/readme.txt).

## Support

If you like the project, leave a :star: (top right) and become a [stargazer](https://github.com/Flowseal/zapret-discrord-youtube/stargazers)!

[![Stargazers repo roster for @Flowseal/zapret-discord-youtube](https://reporoster.com/stars/dark/Flowseal/zapret-discord-youtube)](https://github.com/Flowseal/zapret-discrord-youtube/stargazers)

## Credit
* Many thanks to [bol-van](https://github.com/bol-van/), creator of original [zapret](https://github.com/bol-van/zapret/) repository.
* Appreciation goes to [Flowseal](https://github.com/Flowseal/) for making it possible to use [zapret](https://github.com/bol-van/zapret/tree/master/binaries/win64/zapret-winws) on Windows.
