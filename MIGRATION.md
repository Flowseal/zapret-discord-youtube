# Переход с zapret (zapret1) на zapret2

Репозиторий переведён с [bol-van/zapret](https://github.com/bol-van/zapret)
(`nfqws1` / `winws.exe`) на [bol-van/zapret2](https://github.com/bol-van/zapret2)
(`nfqws2` / `winws2.exe`, движок стратегий — Lua).

Все 22 стратегии `general*.bat` переписаны в синтаксисе zapret2.
Структура каждой стратегии (порядок и фильтры профилей `--new`, хостлисты,
ipset-ы, числа повторов фейков, позиции разрезов, seqovl и т.д.) сохранена —
переписан только механизм воздействия на трафик.

> ⚠️ **Стратегии — не бинарно-идентичные.** zapret2 реализует техники
> zapret1 через библиотеку `zapret-antidpi.lua`, и автор zapret2 прямо
> предупреждает, что алгоритмы (например `multidisorder`) не на 100%
> повторяют nfqws1. Поэтому после перехода **заново проверьте стратегии**
> через `service.bat -> Run Tests` и подберите рабочую именно у вашего
> провайдера.

## Что нужно сделать пользователю

1. Скачать свежий релиз zapret2: <https://github.com/bol-van/zapret2/releases>
   (`zapret2-v*.zip`), достать из него **`winws2.exe`** и положить в папку
   `bin\` рядом с `WinDivert.dll` / `WinDivert64.sys` / `cygwin1.dll`.
   В репозитории бинарника нет: раньше `winws.exe` лежал в `bin\`, теперь
   движок обновляется отдельно и независимо от стратегий.
2. Lua-библиотеки уже лежат в репозитории: `bin\lua\zapret-lib.lua`,
   `bin\lua\zapret-antidpi.lua` (версия из zapret2 v1.0.7). Их подключает
   каждый `general*.bat` через `--lua-init`.
3. Дальше всё как раньше: запуск `general*.bat` вручную или установка
   службой через `service.bat`.

## Как переписывались стратегии

Каждое `--dpi-desync=...` из zapret1 превращалось в цепочку
`--lua-desync=<функция>:<аргументы>` из `zapret-antidpi.lua`, а каждый
профиль получил фильтры `--payload` и `--out-range`, чтобы Lua не вызывался
на лишних пакетах (рекомендация автора zapret2).

| zapret1 | zapret2 |
|---|---|
| `winws.exe` | `winws2.exe` |
| `--wf-tcp=...` / `--wf-udp=...` | `--wf-tcp-out=...` / `--wf-udp-out=...` (перехват разделён по направлениям) |
| `--dpi-desync=fake` + `--dpi-desync-fake-tls=<файл>` | `--blob=<имя>:@"<файл>"` + `--payload=tls_client_hello --lua-desync=fake:blob=<имя>` |
| `--dpi-desync-fake-http=` / `-fake-quic=` / `-fake-unknown=` / `-fake-discord=` / `-fake-stun=` | то же, но секции `--payload=http_req` / `quic_initial` / `unknown` / `discord_ip_discovery,stun` |
| `--dpi-desync-fake-tls=!` (встроенный фейк) | `fake:blob=fake_default_tls` (встроенный блоб zapret2) |
| фейк не задан для протокола | `fake_default_tls` / `fake_default_http` / `fake_default_quic` (встроенные блобы) |
| несколько `--dpi-desync-fake-tls=` в одном профиле | несколько последовательных инстансов `fake:blob=...` — по одному на каждый блоб |
| `--dpi-desync-repeats=N` | `repeats=N` у инстанса `fake` (и у `fakedsplit`/`hostfakesplit`, где повторы относились к их фейкам) |
| `--dpi-desync-fooling=ts` | `tcp_ts=-600000` (значение `ts_increment` по умолчанию в nfqws1) |
| `--dpi-desync-fooling=md5sig` | `tcp_md5` |
| `--dpi-desync-fooling=badseq` | `tcp_seq=<badseq-increment, по умолчанию -10000>:tcp_ack=-66000` |
| `--dpi-desync-fooling=badsum` / `datanoack` | `badsum` / `tcp_flags_unset=ack` |
| `--dpi-desync-fake-tls-mod=rnd,dupsid,sni=...` | `tls_mod=rnd,dupsid,sni=...` у инстанса `fake` (`mod=none` — без эквивалента, просто опущен) |
| `--dpi-desync=multisplit` + `split-pos`/`split-seqovl`/`split-seqovl-pattern` | `multisplit:pos=...:seqovl=...:seqovl_pattern=<blob>` |
| `--dpi-desync=multidisorder` | `multidisorder_legacy:pos=...` (именно `legacy`: порядок сегментов как в nfqws1) |
| `--dpi-desync=fakedsplit` + `fakedsplit-pattern` | `fakedsplit:pattern=<blob или 0xHEX>` (свои фейки функция строит сама) |
| `--dpi-desync=hostfakesplit` + `hostfakesplit-mod=host=X` | `hostfakesplit:host=X` |
| `--dpi-desync=syndata` | `syndata` (без `--payload` перед ним: срабатывает по SYN) |
| `--ip-id=zero` | `ip_id=zero` у генерирующих пакеты инстансов профиля |
| `--dpi-desync-cutoff=nX` | `--out-range=-dX` (см. примечание ниже) |
| `--dpi-desync-any-protocol=1` | `--payload=all` у инстансов + секция `--payload=unknown` |
| профили без cutoff (TCP) | добавлен `--out-range=-d10` (рекомендация автора: Lua отсекается после 10 пакетов с данными) |
| `--filter-*`, `--hostlist*`, `--ipset*` | без изменений — в zapret2 эти фильтры профилей сохранены |

### Примечания о не-один-в-один соответствиях

* **`cutoff=nX` → `-dX`.** В winws2 по умолчанию `--wf-tcp-empty=0`:
  пустые ACK не перехватываются, и счётчик пакетов `n` недостоверен.
  Счётчик `d` (пакеты с данными) работает корректно, поэтому cutoff
  переведён на него. Число пакетов до отсечения сохранено.
* **`hostfakesplit-mod=...,altorder=1`.** В `zapret-antidpi.lua` параметра
  `altorder` нет — он отброшен, `host=...` сохранён.
* **UDP «any protocol» (Game Filter).** В zapret1 `fake` по
  unknown-протоколу слал `fake-unknown-udp`. В zapret2 это
  `--payload=all` + `fake:blob=ACTIVE_GAME_UDP`.
* **Множественные фейки.** Если в профиле zapret1 было два разных
  `--dpi-desync-fake-tls`, теперь отправляются оба блоба подряд —
  поведение может чуть отличаться от nfqws1, который выбирал фейк по
  своему внутреннему порядку.

## Инструменты в репозитории

* `utils/convert_to_zapret2.py` — конвертер, которым были переписаны
  стратегии. Запускается на исходных (zapret1) версиях `general*.bat`
  из git: `git checkout HEAD~1 -- 'general*.bat'` (или из тега до миграции),
  затем `python3 utils/convert_to_zapret2.py`.
* `utils/validate_strategies.py` — статическая проверка переписанных
  стратегий: функции и аргументы сверяются с `bin/lua/zapret-antidpi.lua`,
  блобы и файлы — с `bin/`, остатков синтаксиса zapret1 быть не должно.
* `utils/parse_strategy.ps1` — извлечение аргументов winws2 из
  `general*.bat` при установке службы. Старый построчный парсер
  `service.bat` не понимает `:`/`=` внутри `--lua-desync=...`, поэтому
  `Install Service` теперь пользуется этим скриптом.

## Что ещё изменилось

* `bin/winws.exe` удалён, вместо него ожидается `bin/winws2.exe`
  (см. выше). `WinDivert.dll`, `WinDivert64.sys`, `cygwin1.dll` остались —
  они нужны и winws2.
* `service.bat`: все проверки/остановки процесса и создание службы —
  на `winws2.exe`; при отсутствии бинарника показывает, где его скачать.
* `utils/test zapret.ps1`: ищет/останавливает/восстанавливает `winws2.exe`.
* В каждый `general*.bat` добавлена проверка наличия `winws2.exe`
  с понятной ошибкой вместо молчаливого падения.

## Источники

* zapret2, документация и примеры портирования стратегий:
  <https://github.com/bol-van/zapret2/blob/main/docs/readme.md>
* Полный мануал nfqws2/winws2: <https://github.com/bol-van/zapret2/blob/main/docs/manual.md>
* Библиотека стратегий: `lua/zapret-antidpi.lua` в zapret2.
