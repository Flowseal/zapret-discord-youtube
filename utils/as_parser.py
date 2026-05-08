#!/usr/bin/env python3
import sys
import subprocess
import importlib
import time

# Автоустановка requests, если отсутствует
def ensure_requests():
    try:
        importlib.import_module("requests")
    except ImportError:
        print("Модуль 'requests' не найден. Устанавливаю...")
        subprocess.check_call([sys.executable, "-m", "pip", "install", "--user", "requests"])
        print("Установка завершена. Перезапустите скрипт при необходимости.")
        importlib.import_module("requests")

ensure_requests()

import requests
import ipaddress

ASN_LIST = {
    "Scaleway": "AS12876",
    "Hetzner": "AS24940",
    "Hetzner 2": "AS213230",
    "Hetzner 3": "AS212317",
    "Hetzner 4": "AS215859",
    "Akamai": "AS20940",
    "Akamai 2": "AS16625",
    "Akamai 3": "AS12222",
    "Akamai 4": "AS33905",
    "Akamai 5": "AS21342",
    "Akamai 6": "AS32787",
    "Akamai 7": "AS35994",
    "Akamai 8": "AS12400",
    "Akamai 9": "AS15802",
    "Akamai 10": "AS18209",
    "Akamai 11": "AS24319",
    "Akamai 12": "AS25019",
    "Akamai 13": "AS26008",
    "Akamai 14": "AS31108",
    "Akamai 15": "AS34164",
    "Akamai 16": "AS49846",
    "Akamai 17": "AS17204",
    "Akamai 18": "AS213120",
    "Akamai 19": "AS393234",
    "Akamai 20": "AS393560",
    "Akamai Cloud (Linode)": "AS63949",
    "DigitalOcean": "AS14061",
    "DigitalOcean 2": "AS46652",
    "DigitalOcean 3": "AS393406",
    "Datacamp, CDN77": "AS60068",
    "Datacamp, CDN77 2": "AS212238",
    "Contabo": "AS51167",
    "Contabo 2": "AS141995",
    "Contabo 3": "AS40021",
    "OVH": "AS16276",
    "OVH 2": "AS35540",
    "Vultr (Constant)": "AS20473",
    "Cloudflare": "AS13335",
    "Cloudflare 2": "AS14789",
    "Cloudflare 3": "AS132892",
    "Cloudflare 4": "AS395747",
    "Cloudflare 5": "AS209242",
    "Clouvider": "AS62240",
    "CreaNova": "AS51765",
    "Oracle Cloud": "AS31898",
    "Oracle 2": "AS1219",
    "Amazon": "AS16509",
    "Amazon 2": "AS14618",
    "Amazon 3": "AS8987",
    "G-Core": "AS199524",
    "G-Core 2": "AS202422",
    "Roblox": "AS22697",
    "Fellowship": "AS46461",
    "Fastly": "AS54113",
    "FranTech": "AS53667",
    "LogicForge": "AS208621",
    "Hostinger": "AS47583",
    "Hostinger 2": "AS204915",
    "Ionos": "AS8560",
    "Ionos 2": "AS15418",
    "DreamHost": "AS29873",
    "GoDaddy": "AS26496",
    "GoDaddy 2": "AS398101",
    "HostGator, BlueHost": "AS46606",
    "Cogent": "AS174",
    "Riot Games, Inc": "AS6507",
    "I3DNET (Discord)": "AS49544",
    "IOMART": "AS20860",
    "IOMART 2": "AS21130",
    "Google Cloud": "AS15169",
    "Microsoft Azure": "AS8075",
    "Melbicom": "AS8849",
    "Melbicom 2": "AS56630",
    "M247 Europe SRL": "AS9009",
    "M247 Europe SRL 2": "AS39675",
    "HostPapa, ColoCrossing": "AS36352",
    "Hurricane Electric": "AS6939",
    "GTT Communications": "AS3257",
    "NTT Global": "AS2914",
    "Telia Carrier": "AS1299",
    "Firstcolo": "AS44066",
    "Hosteur": "AS20773",
    "ITL DC": "AS210403",
    "TELECOM ITALIA SPARKLE S.p.A": "AS6762",
    "Orange (FTRSI)": "AS5511",
    "GlobeNet": "AS52320",
    "Lumen": "AS3356",
    "Tata Communications": "AS6453",
    "Verizon Business": "AS701",
    "Scalaxy": "AS58061",
    "Zenlayer": "AS21859",
    "BunnyCDN": "AS5065",
    "Edgio": "AS15133",
    "Edgio 2": "AS22843",
    "StackPath": "AS33438",
    "StackPath 2": "AS202384",
    "KeyCDN": "AS199653",
    "CacheFly": "AS30081",
    "Imperva_Incapsula": "AS19551",
    "Akamai Edgekey)": "AS16625",
    "Constant": "AS20473",
    "Oracle": "AS31898",
    "Linode": "AS63949",
    "I3DNET": "AS49544",
    "Sony": "AS33353",
    "Nintendo": "AS11278",
    "Telegram": "AS211157",
    "Telegram 2": "AS62041",
    "Meta": "AS32934",
    "Netflix": "AS40027",
    "Google": "AS396982",
    "The Constant Company": "AS20473",
    "Prime Formation GmbH": "AS205634",
    "GitHub": "AS36459",
    "Telegram 2": "AS62041",
}

API_URL = "https://stat.ripe.net/data/announced-prefixes/data.json"
TIMEOUT = 15           # таймаут одного запроса, сек
MAX_RETRIES = 10        # число попыток при ошибке
RETRY_DELAY = 5.0      # пауза между попытками, сек
REQUEST_PAUSE = 1.0    # пауза между успешными запросами, чтобы не перегружать API

v4_all = set()
v6_all = set()

for name, asn in ASN_LIST.items():
    print(f"[+] Обработка {name} ({asn}) ...", flush=True)
    success = False
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            r = requests.get(
                API_URL,
                params={"resource": asn, "min_peers_seeing": 1},
                timeout=TIMEOUT
            )
            r.raise_for_status()
            data = r.json().get("data", {}).get("prefixes", [])
            count = 0
            for p in data:
                prefix = p.get("prefix")
                if not prefix:
                    continue
                try:
                    net = ipaddress.ip_network(prefix, strict=False)
                    if net.prefixlen == 0:
                        continue
                    if not net.is_global:
                        continue
                    if net.version == 4:
                        v4_all.add(net)
                    else:
                        v6_all.add(net)
                    count += 1
                except Exception:
                    continue
            print(f"    {count} префиксов добавлено (попытка {attempt})")
            success = True
            break
        except Exception as e:
            print(f"    Ошибка (попытка {attempt}/{MAX_RETRIES}): {e}")
            if attempt < MAX_RETRIES:
                time.sleep(RETRY_DELAY)
    if not success:
        print(f"    Не удалось получить префиксы для {asn} после {MAX_RETRIES} попыток")
    
    time.sleep(REQUEST_PAUSE)   # щадящий режим для API

# Агрегация и сортировка
v4_agg = list(ipaddress.collapse_addresses(
    sorted(v4_all, key=lambda n: (int(n.network_address), n.prefixlen))
))
v6_agg = list(ipaddress.collapse_addresses(
    sorted(v6_all, key=lambda n: (int(n.network_address), n.prefixlen))
))

def sort_key(n):
    return (n.version, int(n.network_address), n.prefixlen)

v4_sorted = sorted(v4_agg, key=sort_key)
v6_sorted = sorted(v6_agg, key=sort_key)

with open("ipset-all.txt", "w", encoding="utf-8") as f:
    for net in v4_sorted:
        f.write(str(net) + "\n")
    for net in v6_sorted:
        f.write(str(net) + "\n")

print("\nГотово!")
print(f"IPv4: {len(v4_sorted)} | IPv6: {len(v6_sorted)} | Всего: {len(v4_sorted)+len(v6_sorted)}")
print("Файл сохранён как ipset-all.txt")
