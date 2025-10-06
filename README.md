<div align="center">

# <img src="https://cdn-icons-png.flaticon.com/128/5968/5968756.png" height=28 /> <a href="https://github.com/Flowseal/">Flowseal</a><a href="https://github.com/Flowseal/zapret-discord-youtube">/zapret-discord-youtube</a> <img src="https://cdn-icons-png.flaticon.com/128/1384/1384060.png" height=28 />

Альтернатива https://github.com/bol-van/zapret-win-bundle  
Также вы можете материально поддержать оригинального разработчика zapret [тут](https://github.com/bol-van/zapret?tab=readme-ov-file#%D0%BF%D0%BE%D0%B4%D0%B4%D0%B5%D1%80%D0%B6%D0%B0%D1%82%D1%8C-%D1%80%D0%B0%D0%B7%D1%80%D0%B0%D0%B1%D0%BE%D1%82%D1%87%D0%B8%D0%BA%D0%B0)
</div>

> [!CAUTION]
>
> ### ФЕЙКИ
> Я не веду никакие другие страницы/группы в телеграм/ютуб каналы  
> Если вы наткнулись на что-то вне этой страницы гитхаба, что распространяется от моего лица - **ФЕЙК**.

> [!WARNING]
>
> ### АНТИВИРУСЫ
> WinDivert может вызвать реакцию антивируса.
> WinDivert - это инструмент для перехвата и фильтрации трафика, необходимый для работы zapret.
> Замена iptables и NFQUEUE в Linux, которых нет под Windows.
> Он может использоваться как хорошими, так и плохими программами, но сам по себе не является вирусом.
> Драйвер WinDivert64.sys подписан для возможности загрузки в 64-битное ядро Windows.
> Но антивирусы склонны относить подобное к классам повышенного риска или хакерским инструментам.
> В случае проблем используйте исключения или выключайте антивирус совсем.
>
> **Выдержка из [`readme.md`](https://github.com/bol-van/zapret-win-bundle/blob/master/readme.md#%D0%B0%D0%BD%D1%82%D0%B8%D0%B2%D0%B8%D1%80%D1%83%D1%81%D1%8B) репозитория [bol-van/zapret-win-bundle](https://github.com/bol-van/zapret-win-bundle)*

> [!IMPORTANT]
> Все бинарные файлы в папке [`bin`](./bin) взяты из [zapret-win-bundle/zapret-winws](https://github.com/bol-van/zapret-win-bundle/tree/master/zapret-winws). Вы можете это проверить с помощью хэшей/контрольных сумм. Проверяйте, что запускаете, используя сборки из интернета!

## ⚙️Использование

1. Включите Secure DNS. В Chrome - "Использовать безопасный DNS", и выбрать поставщика услуг DNS (выбрать вариант, отличный от поставщика по умолчанию). В Firefox - "Включить DNS через HTTPS, используя: Максимальную защиту"
    * В **Windows 11** поддерживается включение Secure DNS прямо в настройках - [инструкция тут](https://www.howtogeek.com/765940/how-to-enable-dns-over-https-on-windows-11/). Рекомендуется, если вы пользуетесь Windows 11

2. Загрузите архив (zip/rar) со [страницы последнего релиза](https://github.com/Flowseal/zapret-discord-youtube/releases/latest)

3. Распакуйте содержимое архива по пути, который не содержит кириллицу/спец. символы

4. Запустите нужный файл

## ℹ️Краткие описания файлов

- [**`general.bat ...`**](./general.bat) - запуск вручную со стратегией для обхода блокировок  

  Запуск вручную можно использовать для проверки работоспособности стратегий. Работоспособность той или иной стратегии зависит от многих факторов. **Пробуйте разные стратегии (ALT, FAKE и другие), пока не найдёте рабочее для вас решение**

- [**`service.bat`**](./service.bat) - установка в автозапуск и другие функции:
  - <ins>**`Install Service`** - установка любой стратегии в автозапуск (services.msc)</ins>
  - **`Remove Services`** - удаление стратегии и WinDivert из служб
  - **`Check Status`** - проверка статуса обхода и служб (стратегии на автозапуске и WinDivert)
  - **`Run Diagnostics`** - диагностика на распространённые причины, по которым zapret может не работать.  
  В конце можно очистить кэш <img src="https://cdn-icons-png.flaticon.com/128/5968/5968756.png" height=11 /> `Discord`, что может помочь, если он неожиданно перестал работать
  - **`Check Updates`** - проверка на обновления
  - **`Switch Game Filter`** - переключение режима обхода для игр (и других сервисов, использующих UDP и TCP на портах выше 1023).  
  **После переключения требуется перезапуск стратегии.**  
  В скобках указан текущий статус (включено/выключено).
  - **`Switch ipset`** - переключение режима обхода сервисов из `ipset-all.txt`.  
  Полезно при тестировании, если не работает то, что не заблокировано.  
  В скобках указан текущий статус (загружен список/пустой список).
  - **`Update ipset list`** - обновление списка `ipset-all.txt` актуальным из репозитория


## ☑️Распространенные вопросы и проблемы

### После запуска скрипта `general*` ничего не происходит

- После запуска стратегии (отдельным bat файлом, не через service), должен открыться winws.exe (обход), который можно увидеть в панели задач.  
Если этого не произошло, то см. [#522](https://github.com/Flowseal/zapret-discord-youtube/issues/522)

### Обход не работает / перестал работать

> [!IMPORTANT]
> **Стратегии блокировок со временем изменяются.**
> Определенная стратегия обхода zapret может работать какое-то время, но если меняется способ блокировки или обнаружения обхода блокировки, то она перестанет работать.
> В репозитории представлены множество различных стратегий для обхода. Если ни одна из них вам не помогает, то вам необходимо создать новую, взяв за основу одну из представленных здесь и изменив её параметры.
> Информацию про параметры стратегий вы можете найти [тут](https://github.com/bol-van/zapret/blob/master/docs/readme.md#nfqws).

- Проверьте, чтобы не было ошибок в `service.bat` -> `Run Diagnostics`

- Убедитесь, что адрес ресурса записан в списках доменов или IP

- Проверьте другие стратегии (**`ALT`**/**`FAKE`** и другие)

- Попробуйте полную переустановку (см. раздел ниже)

- См. [#765](https://github.com/Flowseal/zapret-discord-youtube/issues/765)

### Как переустновить/обновить полностью?
- Сохраните ресурсы/данные, которые вы сами добавляли
- Перезапустите устройство
- `service.bat` -> `Remove Services`
- `service.bat` -> `Run Diagnostics` (если есть ошибки - устраните их) -> в конце Y
- Удалите папку с запретом
- Скачайте последнюю версию [со страницы релизов](https://github.com/Flowseal/zapret-discord-youtube/releases) (`zapret-discord-youtube-...`)
- Распакуйте в новую папку в корне диска (без спец. символов и пробелов)
- Далее пробуйте запускать различные `general` скрипты (стратегии). Проверьте доступность интернет ресурсов - если не работают, то закрывайте программу (в панели задач иконка замочка) и пробуйте другую стратегию
- Как найдёте рабочую стратегию, можете поставить её на автозапуск: `service.bat` -> `Install Service` -> выбираете нужную

### Не работает игра/приложение с включённым запретом

- Проверьте, что в service.bat `Game Filter` **`disabled`**, а `ipset` **`empty`**. Иначе это может затронуть доступность ресурсов, которых вы не ожидали.

### Античит ругается на WinDivert

- Прочитайте инструкцию тут - https://github.com/bol-van/zapret-win-bundle/tree/master/windivert-hide

### Требуется цифровая подпись драйвера WinDivert (Windows 7)

- Замените файлы `WinDivert.dll` и `WinDivert64.sys` в папке [`bin`](./bin) на одноименные из [zapret-win-bundle/win7](https://github.com/bol-van/zapret-win-bundle/tree/master/win7)

### При удалении с помощью [**`service.bat`**](./service.bat), WinDivert остается в службах

1. Узнайте название службы с помощью команды, в командной строке Windows (Win+R, `cmd`):

```cmd
driverquery | find "Divert"
```

2. Остановите и удалите службу командами:

```cmd
sc stop название_из_первого_шага

sc delete название_из_первого_шага
```

### Не работает <img src="https://cdn-icons-png.flaticon.com/128/1384/1384060.png" height=18 /> YouTube

- См. [#251](https://github.com/Flowseal/zapret-discord-youtube/discussions/251)

### Не работает <img src="https://cdn-icons-png.flaticon.com/128/5968/5968756.png" height=18 /> Discord

Работает ли YouTube?
- Если YouTube не работает, значит выбранная вами стратегия не работает. Почините сначала ютуб.
- Если YouTube работает, то проверьте Discord в браузере: https://discord.com/app. Таким образом и пользуйтесь.

  Чтобы починить приложение, и если у вас Windows 11, то вы можете настроить Secure DNS прямо в настройках системы (см. начало README). К сожалению, нет достоверной информации, чинит ли это приложение или нет.

- См. также [#252](https://github.com/Flowseal/zapret-discord-youtube/discussions/252)

### Не нашли своей проблемы

* Создайте её [тут](https://github.com/Flowseal/zapret-discord-youtube/issues)

## 🗒️Добавление адресов прочих заблокированных ресурсов

Список блокирующихся адресов для обхода можно расширить, добавляя их в:
- [`list-general.txt`](./lists/list-general.txt) для доменов (поддомены автоматически учитываются)
- [`ipset-all.txt`](./lists/ipset-all.txt) для IP и подсетей

## ⭐Поддержка проекта

Вы можете поддержать проект, поставив :star: этому репозиторию (сверху справа этой страницы)

Также вы можете материально поддержать оригинального разработчика zapret [тут](https://github.com/bol-van/zapret?tab=readme-ov-file#%D0%BF%D0%BE%D0%B4%D0%B4%D0%B5%D1%80%D0%B6%D0%B0%D1%82%D1%8C-%D1%80%D0%B0%D0%B7%D1%80%D0%B0%D0%B1%D0%BE%D1%82%D1%87%D0%B8%D0%BA%D0%B0)

<a href="https://star-history.com/#Flowseal/zapret-discord-youtube&Date">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=Flowseal/zapret-discord-youtube&type=Date&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=Flowseal/zapret-discord-youtube&type=Date" />
   <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=Flowseal/zapret-discord-youtube&type=Date" />
 </picture>
</a>

## ⚖️Лицензирование

Проект распространяется на условиях лицензии [MIT](https://github.com/Flowseal/zapret-discord-youtube/blob/main/LICENSE.txt)

## 🩷Благодарность участникам проекта

[![Contributors](https://contrib.rocks/image?repo=Flowseal/zapret-discord-youtube)](https://github.com/Flowseal/zapret-discord-youtube/graphs/contributors)

💖 Отдельная благодарность разработчику [zapret](https://github.com/bol-van/zapret) - [bol-van](https://github.com/bol-van)
