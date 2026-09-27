#!/usr/bin/env python3
"""Проба «как браузер»: настоящее TLS-рукопожатие с крупным ClientHello.

curl отправляет ClientHello ~325 байт — он влезает в один TCP-сегмент.
Браузеры шлют ~1500 байт и больше, такой ClientHello рвётся на два сегмента,
и DPI ведёт себя с ним иначе. Поэтому стратегия может давать 8/8 на curl и не
работать в браузере.

Рукопожатие настоящее (OpenSSL сам добавляет постквантовый key_share, как
Chrome), нужный размер при необходимости набирается длинным списком ALPN.

    bigch.py <хост> [порт] [размер] [таймаут] [ключи]
    bigch.py --selfcheck [размер]      — измерить реальный размер ClientHello

Ключи для различающих опытов:
    --small            ClientHello без постквантового key_share: ~520 байт, а с
                       указанным размером — добитый ALPN, но всё ещё в одном сегменте
    --sni <имя|none>   подставить другое имя в SNI или не отправлять SNI вовсе
    --connect <адрес>  соединяться с этим адресом, а SNI взять из <хост>

    код возврата: 0 — рукопожатие прошло, 1 — не прошло, 2 — ошибка
"""
import socket
import ssl
import sys
import threading

# OpenSSL 3.x сам шлёт ClientHello ~1580 байт (в нём постквантовый key_share,
# как у Chrome), поэтому добивка ALPN нужна только для размеров больше этого
# константы выверены самопроверкой (--selfcheck) на OpenSSL 3.x:
BASE_CH = 1538         # свой размер ClientHello с постквантовым key_share, как у Chrome
SMALL_BASE = 337       # то же без постквантового ключа (OpenSSL добивает его до 517
                       # своим padding-расширением, пока содержимое меньше 512 байт)
PER_PROTO = 23         # сколько байт добавляет одна запись ALPN


def make_context(size: int, small: bool = False) -> ssl.SSLContext:
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    if small:
        # TLS 1.3 остаётся, но key_share только P-256 — без постквантового ключа
        # ClientHello ужимается до ~520 байт и влезает в один TCP-сегмент, как у curl.
        # Дальше его можно добить ALPN до любого размера, оставаясь в одном сегменте
        try:
            ctx.set_ecdh_curve("prime256v1")
        except (ssl.SSLError, ValueError):
            ctx.maximum_version = ssl.TLSVersion.TLSv1_2
    n = max(0, (size - (SMALL_BASE if small else BASE_CH)) // PER_PROTO)
    # длинный, но валидный список ALPN: h2 и http/1.1 идут первыми
    protos = ["h2", "http/1.1"] + [f"x-pad-{i:016d}" for i in range(n)]
    try:
        ctx.set_alpn_protocols(protos)
    except Exception:
        ctx.set_alpn_protocols(["h2", "http/1.1"])
    return ctx


def selfcheck(size: int, small: bool = False) -> int:
    """Измеряем настоящий размер ClientHello: слушаем локально и читаем первый пакет."""
    got = {}

    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", 0))
    srv.listen(1)
    port = srv.getsockname()[1]

    def accept():
        conn, _ = srv.accept()
        conn.settimeout(3)
        try:
            got["data"] = conn.recv(65535)
        except OSError:
            got["data"] = b""
        conn.close()

    t = threading.Thread(target=accept, daemon=True)
    t.start()
    ctx = make_context(size, small)
    s = socket.create_connection(("127.0.0.1", port), timeout=3)
    try:
        ctx.wrap_socket(s, server_hostname="www.youtube.com", do_handshake_on_connect=True)
    except Exception:
        pass
    finally:
        s.close()
    t.join(4)
    data = got.get("data", b"")
    if len(data) < 6 or data[0] != 0x16:
        print("не удалось перехватить ClientHello")
        return 2
    rec = int.from_bytes(data[3:5], "big") + 5
    print(f"запрошено ~{size}, реальный ClientHello: {rec} байт "
          f"({'влезает в один сегмент' if rec <= 1400 else 'рвётся на два сегмента'})")
    return 0


def main() -> int:
    args, opts = [], {"small": False, "sni": None, "connect": None}
    it = iter(sys.argv[1:])
    for a in it:
        if a == "--small":
            opts["small"] = True
        elif a in ("--sni", "--connect"):
            opts[a[2:]] = next(it, None)
        else:
            args.append(a)

    if not args:
        print(__doc__.strip())
        return 2
    if args[0] == "--selfcheck":
        return selfcheck(int(args[1]) if len(args) > 1 else 1500, opts["small"])

    host = args[0]
    port = int(args[1]) if len(args) > 1 else 443
    size = int(args[2]) if len(args) > 2 else 1500
    timeout = float(args[3]) if len(args) > 3 else 6.0

    sni = host if opts["sni"] is None else opts["sni"]
    if sni in ("none", "-", ""):
        sni = None
    target = opts["connect"] or host

    ctx = make_context(size, opts["small"])
    try:
        s = socket.create_connection((target, port), timeout=timeout)
    except OSError as e:
        print(f"нет tcp-соединения: {e}")
        return 1
    try:
        s.settimeout(timeout)
        with ctx.wrap_socket(s, server_hostname=sni) as tls:
            print(f"рукопожатие прошло: {tls.version()}, alpn={tls.selected_alpn_protocol()}")
            return 0
    except ssl.SSLError as e:
        # рукопожатие дошло до сервера и он ответил — значит DPI не зарезал
        print(f"сервер ответил ошибкой TLS ({e.reason if hasattr(e, 'reason') else e}) — соединение не зарезано")
        return 0
    except socket.timeout:
        print("таймаут рукопожатия")
        return 1
    except OSError as e:
        print(f"обрыв: {e}")
        return 1
    finally:
        try:
            s.close()
        except OSError:
            pass


if __name__ == "__main__":
    sys.exit(main())
