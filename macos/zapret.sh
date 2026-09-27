#!/bin/bash
#
# zapret-discord-youtube — адаптация для macOS.
#
# Два движка:
#   macws — nfqws (движок winws) + свой бэкенд пакетов для macOS: пакеты берутся
#           из utun (pf route-to) и отправляются заново raw-сокетом. Умеет всё
#           то же, что winws: fake, seqovl, multidisorder, фейки QUIC/STUN/
#           Discord, UDP-игры. Работает напрямую со стратегиями из .bat файлов.
#           IPv4, требует root.
#   tpws  — прозрачный прокси из zapret. Только TCP (split/disorder/oob/tlsrec),
#           зато простой и умеет режим SOCKS без root.
#
# Подробности и ограничения: macos/README.md

set -u
umask 022

ORIG_ARGS=("$@")

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SELF_DIR/.." && pwd)"
LISTS_DIR="$ROOT_DIR/lists"
BIN_DIR="$SELF_DIR/bin"
BUILD_DIR="$SELF_DIR/.build"
STATE_DIR="$SELF_DIR/.state"
SRC_DIR="$SELF_DIR/src"
PATCH_DIR="$SELF_DIR/patches"
TPWS="$BIN_DIR/tpws"
MACWS="$BIN_DIR/macws"
STRATEGIES="$SELF_DIR/strategies.conf"
DEBUG_TOOLS_ENV="${DEBUG_TOOLS-}"   # разовое включение из окружения важнее config

: "${PF_CONF:=/etc/pf.conf}"
: "${PF_ANCHOR:=/etc/pf.anchors/zapret}"
: "${PF_ANCHOR_NAME:=zapret}"
: "${PLIST:=/Library/LaunchDaemons/zapret.plist}"
: "${PIDFILE:=/var/run/zapret-tpws.pid}"
: "${PIDFILE_MACWS:=/var/run/zapret-macws.pid}"
: "${PIDFILE_WATCH:=/var/run/zapret-pfwatch.pid}"
: "${LOG:=/var/log/zapret.log}"

# ---------------------------------------------------------------- настройки --
# Переопределяются в macos/config (см. macos/config.example) или через окружение
: "${ENGINE:=auto}"                                  # auto | macws | tpws
: "${STRATEGY_BAT:=general.bat}"                     # стратегия macws (.bat)
: "${STRATEGY:=disorder}"                            # стратегия tpws
: "${GAME_FILTER:=off}"                              # off | tcp | udp | all
: "${GAME_PORTS:=1024-65535}"                        # диапазон для game filter
: "${TCP_PORTS:=80,443,2053,2083,2087,2096,8443}"    # порты tpws
: "${TPWS_PORT:=988}"
: "${SOCKS_PORT:=1080}"
: "${BLOCK_QUIC:=1}"                                 # только для tpws
: "${IPV6:=auto}"                                    # auto | 1 | 0 (tpws)
: "${IPSET_FILTER:=none}"                            # none | loaded | any (как IPSet Filter в service.bat)
: "${USE_IPSET:=auto}"
: "${USE_LISTS:=1}"
: "${TEST_TIMEOUT:=5}"
: "${BIGCH_SIZE:=0}"                                  # размер ClientHello браузерной пробы; 0 — как у браузера (1538)
: "${TEST_PORT:=10800}"
: "${TARGETS_FILE:=$ROOT_DIR/utils/targets.txt}"
: "${ZAPRET_TAG:=v72.9}"
: "${UTUN_LOCAL:=10.77.77.1}"
: "${UTUN_PEER:=10.77.77.2}"
: "${UTUN_PEER6:=fd77:77::2}"
: "${DNS6_PROBE:=2001:4860:4860::8888}"
: "${QUIC:=block}"                                   # block | fake — QUIC/HTTP3 (udp 443) для macws
: "${PF_WATCH:=1}"                                   # следить, что активный ruleset pf не затёрли
: "${PF_WATCH_INTERVAL:=10}"
: "${PF_TAKEOVER:=auto}"                             # auto | 1 | 0 — дописывать ли ссылку на anchor в активный ruleset pf
: "${ENGINE_LOG:=}"                                  # файл лога движка (в тестах ставится сам)
: "${DEBUG_TOOLS:=0}"                                # 1 — отладочные функции, которых нет в оригинале (см. README)
: "${IPSET_URL:=https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/refs/heads/main/.service/ipset-service.txt}"
[ -f "$SELF_DIR/config" ] && . "$SELF_DIR/config"
[ -n "$DEBUG_TOOLS_ENV" ] && DEBUG_TOOLS="$DEBUG_TOOLS_ENV"

# Отладочные функции (подробные логи, их разбор, подбор параметров, пробы) в
# оригинале нет — по умолчанию они выключены, но не удалены. DEBUG_TOOLS=1
# включает команды и расширенную диагностику в самом движке (MACWS_DIAG).
debug_tools_on() { [ "$DEBUG_TOOLS" = 1 ]; }
debug_tools_on && export MACWS_DIAG=1

# ------------------------------------------------------------------ утилиты --
if [ -t 1 ]; then C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[1m'; C_D=$'\033[2m'; C_0=$'\033[0m'
else C_R=; C_G=; C_Y=; C_B=; C_D=; C_0=; fi

msg()  { printf '%s\n' "$*"; }
ok()   { printf '%s%s%s\n' "$C_G" "$*" "$C_0"; }
warn() { printf '%s%s%s\n' "$C_Y" "$*" "$C_0" >&2; }
require_debug_tools() {
	debug_tools_on && return 0
	warn "«$1» — отладочная функция, её нет в оригинале, и по умолчанию она выключена."
	warn "Включить: DEBUG_TOOLS=1 в macos/config (или разово: sudo DEBUG_TOOLS=1 $0 $1 ...)"
	exit 1
}
die()  { printf '%s%s%s\n' "$C_R" "$*" "$C_0" >&2; exit 1; }

require_root() {
	[ "$(id -u)" = 0 ] && return 0
	command -v sudo >/dev/null || die "нужны права root"
	msg "нужны права root, запускаю через sudo..."
	exec sudo -- "$0" "${ORIG_ARGS[@]}"
}

ipv6_on() {
	case "$IPV6" in
		1|yes|on) return 0 ;;
		0|no|off) return 1 ;;
	esac
	route -n get -inet6 default >/dev/null 2>&1
}

# заворачивать ли IPv6 движком macws:
# auto — если есть маршрут в ipv6-интернет и selftest подтвердил инъекцию v6
ipv6_route_exists() {
	route -n get -inet6 "$DNS6_PROBE" >/dev/null 2>&1 || route -n get -inet6 default >/dev/null 2>&1
}

ipv6_macws_on() {
	case "$IPV6" in
		1|yes|on) return 0 ;;
		0|no|off) return 1 ;;
	esac
	[ -f "$STATE_DIR/macws-v6-ok" ] || return 1
	ipv6_route_exists
}

ipset_on() {
	local n=0
	case "$USE_IPSET" in
		0|no|off) return 1 ;;
		1|yes|on) [ -s "$LISTS_DIR/ipset-all.txt" ] ;;
		*)  [ -f "$LISTS_DIR/ipset-all.txt" ] && n="$(grep -c . "$LISTS_DIR/ipset-all.txt" 2>/dev/null || true)"
			[ "${n:-0}" -ge 10 ] 2>/dev/null ;;
	esac
}

# движок: auto -> macws, если собран и прошёл selftest
engine() {
	case "$ENGINE" in
		macws|tpws) printf '%s' "$ENGINE"; return ;;
	esac
	if [ -x "$MACWS" ] && [ -f "$STATE_DIR/macws-ok" ]; then printf '%s' macws; else printf '%s' tpws; fi
}

tls_ports() { printf '%s' "$TCP_PORTS" | tr ',' '\n' | grep -v '^80$' | paste -sd, - ; }

# ------------------------------------------------------------------- сборка --
fetch_src() {
	command -v cc >/dev/null || die "нет компилятора. Установите Command Line Tools: xcode-select --install"
	mkdir -p "$BUILD_DIR" "$BIN_DIR"
	SRC="$BUILD_DIR/zapret-${ZAPRET_TAG#v}"
	[ -d "$SRC" ] || {
		msg "скачиваю исходники zapret $ZAPRET_TAG..."
		curl -fsSL "https://github.com/bol-van/zapret/archive/refs/tags/$ZAPRET_TAG.tar.gz" \
			| tar -xzf - -C "$BUILD_DIR" || die "не удалось скачать/распаковать исходники"
	}
	[ -d "$SRC/tpws" ] || die "нет исходников в $SRC (проверьте ZAPRET_TAG=$ZAPRET_TAG)"
}

# Бинарник кладём новым файлом, а не поверх старого: на Apple Silicon запись
# поверх уже запускавшегося файла ломает проверку подписи кода, и ядро убивает
# процесс при запуске (Killed: 9)
install_bin() {
	rm -f "$2" && cp "$1" "$2" && chmod 755 "$2"
}

build_tpws() {
	msg "собираю tpws..."
	make -C "$SRC/tpws" mac >/dev/null || die "сборка tpws не удалась"
	install_bin "$SRC/tpws/tpws" "$TPWS"
	ok "tpws: $("$TPWS" --version 2>&1 | head -1)"
}

build_macws() {
	local patch="$PATCH_DIR/macws-${ZAPRET_TAG#v}.patch"
	[ -f "$patch" ] || { warn "нет патча $patch — macws для $ZAPRET_TAG не собирается, только tpws"; return 1; }
	# патч бэкенда накладывается один раз на распакованное дерево
	[ -f "$SRC/nfq/mac_backend.c" ] || {
		msg "накладываю патч бэкенда macws..."
		( cd "$SRC" && patch -p1 --forward < "$patch" ) || die "патч не наложился"
	}
	cp -f "$SRC_DIR/mac_backend.c" "$SRC_DIR/mac_backend.h" "$SRC/nfq/"
	msg "собираю macws (движок nfqws + бэкенд utun)..."
	make -C "$SRC/nfq" mac >/dev/null || die "сборка macws не удалась"
	install_bin "$SRC/nfq/dvtws" "$MACWS"
	ok "macws: $("$MACWS" --version 2>&1 | head -1)"
}

cmd_build() {
	fetch_src
	build_tpws
	build_macws || true
	build_bigch || true
	[ -x "$MACWS" ] && msg "проверить бэкенд macws: sudo ./macos/zapret.sh selftest"
	return 0
}

ensure_engine() {
	case "$(engine)" in
		macws) [ -x "$MACWS" ] || cmd_build ;;
		tpws)  [ -x "$TPWS" ]  || cmd_build ;;
	esac
}

# -------------------------------------------------- стратегии .bat (macws) ---
bat_list() { ( cd "$ROOT_DIR" && ls *.bat 2>/dev/null | grep -v '^service\.bat$' ); }

# принимает "general.bat", "ALT4", "general (ALT4)" и т.п.
bat_resolve() {
	local q="${1:-$STRATEGY_BAT}" f
	[ -f "$ROOT_DIR/$q" ] && { printf '%s' "$ROOT_DIR/$q"; return 0; }
	[ -f "$ROOT_DIR/$q.bat" ] && { printf '%s' "$ROOT_DIR/$q.bat"; return 0; }
	[ -f "$ROOT_DIR/general ($q).bat" ] && { printf '%s' "$ROOT_DIR/general ($q).bat"; return 0; }
	f="$(bat_list | grep -i -- "$q" | head -1)"
	[ -n "$f" ] && { printf '%s' "$ROOT_DIR/$f"; return 0; }
	return 1
}

game_filter_tcp() { case "$GAME_FILTER" in tcp|all) printf '%s' "$GAME_PORTS" ;; *) printf '12' ;; esac; }
game_filter_udp() { case "$GAME_FILTER" in udp|all) printf '%s' "$GAME_PORTS" ;; *) printf '12' ;; esac; }

# аргументы winws из .bat -> аргументы macws (готовы для eval "set -- ...")
bat_args() {
	local bat="$1"
	tr -d '\r' < "$bat" | awk '
		/^start .*winws\.exe/ { inblk=1 }
		inblk { line=$0; sub(/\^$/,"",line); printf "%s", line " "; if ($0 !~ /\^$/) { print ""; inblk=0 } }
	' | sed -e 's/^.*winws\.exe"//' \
	        -e 's/\^\([!&|<>^]\)/\1/g' \
	        -e "s|%BIN%|$ROOT_DIR/bin/|g" -e "s|%LISTS%|$LISTS_DIR/|g" \
	        -e "s|%GameFilterTCP%|$(game_filter_tcp)|g" -e "s|%GameFilterUDP%|$(game_filter_udp)|g" \
	  | tr ' ' '\n' \
	  | grep -v '^--wf-tcp=\|^--wf-udp=\|^--wf-raw=\|^--wf-raw-part=\|^$' \
	  | awk -F= '
	      /^--(hostlist|hostlist-exclude|ipset|ipset-exclude)=/ {
	         f=$2; gsub(/"/,"",f);
	         if (system("[ -s \"" f "\" ]") != 0) next
	      }
	      { print }' \
	  | sed -e "s|$LISTS_DIR/ipset-all.txt|$(ipset_file)|g" \
	  | awk -v g="$LISTS_DIR/list-google.txt" -v add="$([ "$QUIC" = fake ] && [ -s "$LISTS_DIR/list-google.txt" ] && echo 1)" '
	      # QUIC-профили в .bat смотрят только в list-general, поэтому видео
	      # YouTube (googlevideo.com живёт в list-google) по HTTP/3 не
	      # обрабатывается. В режиме fake дополняем такой профиль list-google.
	      /^--new$/ { udp=0 }
	      /^--filter-udp=/ { udp=1 }
	      { print }
	      add && udp && /^--hostlist=.*list-general\.txt"?$/ { printf "--hostlist=\"%s\"\n", g }' \
	  | paste -sd' ' -
}

# IPSet Filter, как в service.bat:
#   none   — список не используется (в репозитории ipset-all.txt и есть заглушка);
#            профили по ipset не матчатся, и работают профили по хостлистам
#   loaded — полный список адресов (для целей, где имя не видно)
#   any    — под фильтр попадает любой адрес
# Файлы репозитория при этом не меняются: подменяется только путь в аргументах.
ipset_file() {
	local out
	case "$IPSET_FILTER" in
		loaded)
			# Список в репозитории (.service/ipset-service.txt, он же
			# lists/ipset-all.txt.backup в формате Windows) обновляется при
			# синхронизации с оригиналом, копия в .state — командой update-ipset.
			# Берём ту, что свежее: иначе после синхронизации остался бы старый кэш
			local src= f
			out="$STATE_DIR/ipset-loaded.txt"
			for f in "$ROOT_DIR/.service/ipset-service.txt" "$LISTS_DIR/ipset-all.txt.backup"; do
				[ -s "$f" ] && { src="$f"; break; }
			done
			mkdir -p "$STATE_DIR"
			if [ -n "$src" ] && { [ ! -s "$out" ] || [ "$src" -nt "$out" ]; }; then
				tr -d '\r' < "$src" > "$out.tmp" && mv -f "$out.tmp" "$out" || return 1
			elif [ ! -s "$out" ]; then
				curl -fsSL "$IPSET_URL" -o "$out.tmp" && mv -f "$out.tmp" "$out" || return 1
			fi
			printf '%s' "$out" ;;
		any)
			out="$STATE_DIR/ipset-any.txt"
			mkdir -p "$STATE_DIR"
			printf '0.0.0.0/0\n::/0\n' > "$out"
			printf '%s' "$out" ;;
		*)  printf '%s' "$LISTS_DIR/ipset-all.txt" ;;
	esac
}

# порты из --wf-tcp/--wf-udp -> список для pf (19294-19344 -> 19294:19344)
bat_wf_ports() {
	# $1 - .bat, $2 - tcp|udp
	tr -d '\r' < "$1" | grep -o -- "--wf-$2=[^ ^]*" | head -1 | sed "s/--wf-$2=//" \
	  | sed -e "s|%GameFilterTCP%|$(game_filter_tcp)|g" -e "s|%GameFilterUDP%|$(game_filter_udp)|g" \
	  | tr ',' '\n' | sed -e 's/-/:/' -e '/^$/d' | paste -sd, -
}

# ----------------------------------------------------------------------- pf --
pf_table_file() {
	local out="$STATE_DIR/$1"; shift
	mkdir -p "$STATE_DIR"
	{ local f; for f in "$@"; do [ -s "$f" ] && cat "$f"; done; } \
		| tr -d '\r' | sed -e 's/[#;].*$//' -e 's/[[:space:]]//g' -e '/^$/d' > "$out"
	printf '%s' "$out"
}

nozapret_file() {
	pf_table_file nozapret.txt "$LISTS_DIR/ipset-exclude.txt" "$LISTS_DIR/ipset-exclude-user.txt"
}

# правила pf для tpws (rdr + route-to на локальный порт)
pf_rules_tpws() {
	local ports="{$TCP_PORTS}" nozapret
	nozapret="$(nozapret_file)"
	echo "# tpws | файл создаётся macos/zapret.sh"
	echo "table <nozapret> persist file \"$nozapret\""
	echo "rdr pass on lo0 inet proto tcp from !127.0.0.0/8 to !<nozapret> port $ports -> 127.0.0.1 port $TPWS_PORT"
	ipv6_on && echo "rdr pass on lo0 inet6 proto tcp from !::1 to !<nozapret> port $ports -> fe80::1 port $TPWS_PORT"
	echo "pass out quick route-to (lo0 127.0.0.1) inet proto tcp from any to !<nozapret> port $ports user { >root }"
	ipv6_on && echo "pass out quick route-to (lo0 fe80::1) inet6 proto tcp from any to !<nozapret> port $ports user { >root }"
	[ "$BLOCK_QUIC" = 1 ] && {
		echo "block return out quick inet proto udp from any to !<nozapret> port 443"
		ipv6_on && echo "block return out quick inet6 proto udp from any to !<nozapret> port 443"
	}
	true
}

# Исключать трафик root из заворота нужно только если движок отправляет пакеты
# raw-сокетом (он проходит через pf -> была бы петля). При инъекции через bpf
# пакеты в pf не попадают, поэтому обход работает и для root.
root_exclusion() {
	[ "$(cat "$STATE_DIR/macws-inject" 2>/dev/null)" = bpf ] || printf ' user { >root }'
}

# правила pf для macws (заворот в utun; %UTUN% подставляет сам macws)
pf_rules_macws() {
	local bat="$1" tcp udp nozapret
	tcp="$(bat_wf_ports "$bat" tcp)"
	udp="$(bat_wf_ports "$bat" udp)"
	nozapret="$(nozapret_file)"
	echo "# macws | файл создаётся macos/zapret.sh"
	echo "table <nozapret> persist file \"$nozapret\""
	# no state: pf не ведёт состояние по завёрнутым потокам — его проверка
	# seq/окна рубила бы рассинхронизированные пакеты, а ответ приходит с другого
	# интерфейса, чем ушёл запрос
	local ex; ex="$(root_exclusion)"
	# QUIC: движок умеет фейки, но если они не помогают, браузер висит на HTTP/3,
	# хотя TCP уже обходится. block глушит udp/443 с ответом, и браузер уходит на TCP
	[ "$QUIC" = block ] && echo "block return out quick inet proto udp from any to !<nozapret> port 443"
	# quick обязателен: без него в pf решает ПОСЛЕДНЕЕ совпавшее правило, и наш
	# заворот отменяет любое более позднее (например из анкера com.apple)
	[ -n "$tcp" ] && echo "pass out quick route-to (%UTUN% $UTUN_PEER) inet proto tcp from any to !<nozapret> port {$tcp}$ex no state"
	[ -n "$udp" ] && echo "pass out quick route-to (%UTUN% $UTUN_PEER) inet proto udp from any to !<nozapret> port {$udp}$ex no state"
	if ipv6_macws_on; then
		[ -n "$tcp" ] && echo "pass out quick route-to (%UTUN% $UTUN_PEER6) inet6 proto tcp from any to !<nozapret> port {$tcp}$ex no state"
		[ -n "$udp" ] && echo "pass out quick route-to (%UTUN% $UTUN_PEER6) inet6 proto udp from any to !<nozapret> port {$udp}$ex no state"
	elif [ "$IPV6" != 0 ] && ipv6_route_exists; then
		# IPv6 не заворачиваем (не проверен или выключен), но сайты dual-stack
		# пойдут именно по нему и обход мимо. Глушим v6 на этих портах, чтобы
		# клиент вернулся на IPv4, который мы обходим.
		[ -n "$tcp" ] && echo "block return out quick inet6 proto tcp from any to !<nozapret> port {$tcp}"
		[ -n "$udp" ] && echo "block return out quick inet6 proto udp from any to !<nozapret> port {$udp}"
	fi
	true
}

pf_conf_patch() {
	grep -q "^anchor \"$PF_ANCHOR_NAME\"\$" "$PF_CONF" && grep -q "^rdr-anchor \"$PF_ANCHOR_NAME\"\$" "$PF_CONF" && return 0
	mkdir -p "$STATE_DIR"
	[ -f "$STATE_DIR/pf.conf.orig" ] || cp -p "$PF_CONF" "$STATE_DIR/pf.conf.orig"
	msg "прописываю anchor \"$PF_ANCHOR_NAME\" в $PF_CONF (копия: $STATE_DIR/pf.conf.orig)"
	grep -q "^rdr-anchor \"$PF_ANCHOR_NAME\"\$" "$PF_CONF" || sed -i '' -e '/^rdr-anchor "com\.apple\/\*"$/i\
rdr-anchor "'"$PF_ANCHOR_NAME"'"
' "$PF_CONF"
	grep -q "^anchor \"$PF_ANCHOR_NAME\"\$" "$PF_CONF" || sed -i '' -e '/^anchor "com\.apple\/\*"$/i\
anchor "'"$PF_ANCHOR_NAME"'"
' "$PF_CONF"
	grep -q "^anchor \"$PF_ANCHOR_NAME\"\$" "$PF_CONF" && grep -q "^rdr-anchor \"$PF_ANCHOR_NAME\"\$" "$PF_CONF" || {
		warn "не удалось пропатчить $PF_CONF. Добавьте вручную:"
		warn "  rdr-anchor \"$PF_ANCHOR_NAME\"   (перед rdr-anchor \"com.apple/*\")"
		warn "  anchor \"$PF_ANCHOR_NAME\"       (перед anchor \"com.apple/*\")"
		return 1
	}
	pfctl -qf "$PF_CONF" || return 1
}

pf_conf_unpatch() {
	[ -f "$PF_CONF" ] || return 0
	sed -i '' -e "/^anchor \"$PF_ANCHOR_NAME\"\$/d" -e "/^rdr-anchor \"$PF_ANCHOR_NAME\"\$/d" "$PF_CONF"
	pfctl -qf "$PF_CONF" 2>/dev/null
	rm -f "$PF_ANCHOR"
}

# Ссылается ли ЗАГРУЖЕННЫЙ ruleset на наш anchor. Проверять /etc/pf.conf
# недостаточно: сторонние клиенты (VPN и пр.) грузят свой ruleset через
# pfctl -f, и наши ссылки из pf.conf в активном наборе просто отсутствуют —
# правила лежат в анкере, но никто их не вычисляет.
pf_anchor_active() { pfctl -sr 2>/dev/null | grep -q "^anchor \"$PF_ANCHOR_NAME\""; }

# какой utun поднял движок: ищем по нашему адресу
utun_current() {
	ifconfig 2>/dev/null | awk -v a="$UTUN_LOCAL" '
		/^utun[0-9]+:/ { i=substr($1,1,length($1)-1) }
		$1=="inet" && $2==a { print i; exit }'
}

# уходит ли трафик в туннель (тогда обход не нужен и pf трогать не стоит)
uplink_is_tunnel() {
	local i; i="$(route -n get 8.8.8.8 2>/dev/null | awk '/interface:/{print $2;exit}')"
	case "$i" in utun*|ipsec*|ppp*|gpd*) return 0 ;; *) return 1 ;; esac
}

pf_ensure_anchor_active() {
	pf_anchor_active && return 0
	local owner main
	owner="$(pfctl -sA 2>/dev/null | tr -d ' ' | grep -vx "$PF_ANCHOR_NAME" | grep -vx 'com.apple' | paste -sd, -)"
	warn "активный ruleset pf не ссылается на anchor \"$PF_ANCHOR_NAME\"${owner:+ — его загрузил $owner}"
	uplink_is_tunnel && {
		warn "и трафик сейчас уходит в туннель: сначала отключите VPN, обход сквозь него бессмысленен"
		return 1
	}
	case "$PF_TAKEOVER" in
		0|no|off)
			warn "заворот не сработает. Либо закройте клиент, перезаписавший pf, и выполните"
			warn "  sudo pfctl -f $PF_CONF"
			warn "либо разрешите дописать ссылку: PF_TAKEOVER=1 в macos/config"
			return 1 ;;
	esac
	# собираем главный ruleset заново: всё, что есть сейчас, плюс наши ссылки.
	# правила и анкеры остальных (в том числе VPN) сохраняются
	main="$STATE_DIR/pf.main"
	mkdir -p "$STATE_DIR"
	{
		grep -E '^(scrub|dummynet)-anchor' "$PF_CONF" 2>/dev/null
		pfctl -sn 2>/dev/null | grep -v "\"$PF_ANCHOR_NAME\""
		echo "rdr-anchor \"$PF_ANCHOR_NAME\""
		pfctl -sr 2>/dev/null | grep -v "\"$PF_ANCHOR_NAME\""
		echo "anchor \"$PF_ANCHOR_NAME\""
	} > "$main"
	if ! pfctl -n -f "$main" >/dev/null 2>&1; then
		warn "не удалось собрать совместимый ruleset, ничего не меняю:"
		pfctl -n -f "$main" 2>&1 | grep -v 'Use of -f option\|present in the main ruleset\|See /etc/pf\.conf' | head -5 >&2
		return 1
	fi
	pfctl -f "$main" 2>/dev/null || { warn "pfctl -f не принял собранный ruleset"; return 1; }
	msg "в активный ruleset pf добавлена ссылка на anchor \"$PF_ANCHOR_NAME\" (правила остальных сохранены)"
	msg "вернуть как было: sudo pfctl -f $PF_CONF"
	pf_anchor_active
}

# Сторож: сторонний клиент (VPN и пр.) может перезагрузить свой ruleset в любой
# момент и снова затереть ссылку на наш anchor — тогда обход молча выключается.
pf_watch_stop() {
	local pid=
	[ -f "$PIDFILE_WATCH" ] && read -r pid < "$PIDFILE_WATCH"
	[ -n "$pid" ] && kill "$pid" 2>/dev/null
	rm -f "$PIDFILE_WATCH"
	return 0
}

# Сторож решает две задачи:
#  1) сторонний клиент затёр ссылку на наш anchor — восстановить;
#  2) поднялся VPN — приостановить обход. Сквозь туннель он не нужен, а хуже
#     того: мы бы заворачивали уже туннельный трафик и отправляли его кадром
#     в физический интерфейс, мимо туннеля — именно от этого перестают
#     грузиться сайты. Когда туннель уходит, обход возвращается сам.
pf_watch_start() {
	[ "$PF_WATCH" = 0 ] && return 0
	[ -n "${IN_WATCHDOG:-}" ] && return 0
	pf_watch_stop
	local strat; strat="$(cat "$STATE_DIR/strategy" 2>/dev/null)"
	(
		export IN_WATCHDOG=1
		trap '' HUP
		local suspended=0 u=
		while :; do
			sleep "$PF_WATCH_INTERVAL"
			# движок остановили — сторож больше не нужен
			[ -n "$(macws_pid)$(tpws_pid)" ] || break

			if uplink_is_tunnel; then
				[ "$suspended" = 1 ] && continue
				msg "$(date '+%H:%M:%S') поднят туннель (VPN): снимаю правила заворота — сквозь туннель обход не нужен,"
				msg "           а заворот ломал бы туннельный трафик. Вернётся, когда туннель уйдёт."
				pfctl -qa "$PF_ANCHOR_NAME" -F all 2>/dev/null
				suspended=1
				continue
			fi

			if [ "$suspended" = 1 ]; then
				u="$(utun_current)"
				if [ -n "$u" ] && [ -s "$STATE_DIR/macws.pf" ]; then
					sed "s/%UTUN%/$u/g" "$STATE_DIR/macws.pf" | pfctl -qa "$PF_ANCHOR_NAME" -f - 2>/dev/null
				elif [ -s "$PF_ANCHOR" ]; then
					pfctl -qa "$PF_ANCHOR_NAME" -f "$PF_ANCHOR" 2>/dev/null
				fi
				pf_ensure_anchor_active >/dev/null 2>&1
				msg "$(date '+%H:%M:%S') туннель ушёл: правила заворота возвращены"
				suspended=0
				continue
			fi

			pf_anchor_active || {
				msg "$(date '+%H:%M:%S') pf: ссылку на anchor \"$PF_ANCHOR_NAME\" затёрли, восстанавливаю"
				pf_ensure_anchor_active >/dev/null 2>&1
			}
		done
		rm -f "$PIDFILE_WATCH"
	) >>"$LOG" 2>&1 &
	echo $! > "$PIDFILE_WATCH"
	return 0
}

# Служба launchd поднимает движок сама и с KeepAlive переживает kill, поэтому
# ручной запуск должен её сначала выгрузить — иначе получаются два экземпляра
service_loaded() { launchctl print system/zapret >/dev/null 2>&1; }

service_stop() {
	service_loaded || return 0
	launchctl bootout system/zapret 2>/dev/null || launchctl unload -w "$PLIST" 2>/dev/null
	msg "служба автозапуска остановлена"
	return 0
}

pf_watch_running() {
	local pid=
	[ -f "$PIDFILE_WATCH" ] && read -r pid < "$PIDFILE_WATCH"
	# ps, а не kill -0: без sudo kill -0 на процесс root даёт «нет прав»
	[ -n "$pid" ] && ps -p "$pid" >/dev/null 2>&1
}

pf_enable() {
	mkdir -p "$STATE_DIR"
	[ -s "$STATE_DIR/pf.token" ] || {
		pfctl -E 2>&1 | sed -nE 's/^[[:space:]]*Token[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' > "$STATE_DIR/pf.token"
		[ -s "$STATE_DIR/pf.token" ] || { rm -f "$STATE_DIR/pf.token"; pfctl -qe 2>/dev/null; }
	}
}

pf_down() {
	pfctl -qa "$PF_ANCHOR_NAME" -F all 2>/dev/null
	[ -s "$STATE_DIR/pf.token" ] && { pfctl -X "$(cat "$STATE_DIR/pf.token")" >/dev/null 2>&1; rm -f "$STATE_DIR/pf.token"; }
	msg "pf: правила zapret выгружены"
}

# ------------------------------------------------------------ tpws-профили ---
ARGS=()
add() { ARGS+=("$@"); }
add_words() { local w; for w in $1; do ARGS+=("$w"); done; }

PROFILE_STARTED=0
new_profile() { [ "$PROFILE_STARTED" = 1 ] && add --new; PROFILE_STARTED=1; }

add_hostlists() {
	local f
	for f in list-general.txt list-general-user.txt list-google.txt list-google-user.txt; do
		[ -s "$LISTS_DIR/$f" ] && add "--hostlist=$LISTS_DIR/$f"
	done
	add_excludes
}

add_excludes() {
	local f
	for f in list-exclude.txt list-exclude-user.txt; do
		[ -s "$LISTS_DIR/$f" ] && add "--hostlist-exclude=$LISTS_DIR/$f"
	done
	for f in ipset-exclude.txt ipset-exclude-user.txt; do
		[ -s "$LISTS_DIR/$f" ] && add "--ipset-exclude=$LISTS_DIR/$f"
	done
}

strategy_field() {
	awk -F'|' -v n="$1" -v f="$2" '
		/^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
		{ gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1); if ($1 != n) next
		  v=$f; gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); print v; exit }
	' "$STRATEGIES"
}
strategy_names() {
	awk -F'|' '/^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
		{ gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1); print $1 }' "$STRATEGIES"
}
strategy_exists() { strategy_names | grep -qx "$1"; }

build_args() {
	local mode="$1" strat="$2" tls http
	strategy_exists "$strat" || die "неизвестная стратегия tpws: $strat (см. $0 list)"
	tls="$(strategy_field "$strat" 2)"
	http="$(strategy_field "$strat" 3)"

	ARGS=(); PROFILE_STARTED=0
	case "$mode" in
		transparent)
			add "--port=$TPWS_PORT" --user=root --bind-addr=127.0.0.1
			ipv6_on && add --bind-iface6=lo0 --bind-linklocal=force
			;;
		socks)
			add --socks "--port=$SOCKS_PORT" --bind-addr=127.0.0.1
			ipv6_on && add --bind-addr=::1
			;;
		test)
			add --socks "--port=${3:-$TEST_PORT}" --bind-addr=127.0.0.1
			;;
	esac

	if [ "$mode" = test ]; then
		[ -n "$http" ] && { new_profile; add --filter-tcp=80; add_words "$http"; }
		[ -n "$tls" ] && { new_profile; add "--filter-tcp=$(tls_ports)"; add_words "$tls"; }
		return 0
	fi

	if [ "$USE_LISTS" = 1 ]; then
		[ -n "$http" ] && { new_profile; add --filter-tcp=80; add_hostlists; add_words "$http"; }
		[ -n "$tls" ] && { new_profile; add "--filter-tcp=$(tls_ports)"; add_hostlists; add_words "$tls"; }
		[ -n "$tls" ] && ipset_on && {
			new_profile; add "--filter-tcp=$(tls_ports)" "--ipset=$LISTS_DIR/ipset-all.txt"
			[ -s "$LISTS_DIR/ipset-all-user.txt" ] && add "--ipset=$LISTS_DIR/ipset-all-user.txt"
			add_excludes; add_words "$tls"; add --split-any-protocol
		}
	else
		[ -n "$http" ] && { new_profile; add --filter-tcp=80; add_excludes; add_words "$http"; }
		[ -n "$tls" ] && { new_profile; add "--filter-tcp=$(tls_ports)"; add_excludes; add_words "$tls"; }
	fi
	return 0
}

# ------------------------------------------------------------------ процессы --
proc_pid() {
	# $1 - pidfile, $2 - паттерн для pgrep
	local pid=
	[ -f "$1" ] && read -r pid < "$1"
	[ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && { printf '%s' "$pid"; return 0; }
	pgrep -f "$2" | head -1
}
tpws_pid()  { proc_pid "$PIDFILE"       "$TPWS .*--port=$TPWS_PORT"; }
macws_pid() { proc_pid "$PIDFILE_MACWS" "$MACWS "; }

# Гасим ВСЕ экземпляры, а не первый попавшийся: иначе после start + debug
# остаются два движка, два utun с одинаковым адресом и каша в pf
proc_stop_all() {
	local pat="$1" file="$2" pid
	[ -f "$file" ] && { read -r pid < "$file" || true; [ -n "${pid:-}" ] && kill "$pid" 2>/dev/null; }
	for pid in $(pgrep -f "$pat" 2>/dev/null); do kill "$pid" 2>/dev/null; done
	sleep 0.5
	for pid in $(pgrep -f "$pat" 2>/dev/null); do kill -9 "$pid" 2>/dev/null; done
	rm -f "$file"
	return 0
}
engines_stop() {
	proc_stop_all "$MACWS " "$PIDFILE_MACWS"
	proc_stop_all "$TPWS .*--port=$TPWS_PORT" "$PIDFILE"
	tso_restore
}

# Движок на время заворота выключает TSO (иначе pf выбрасывает крупные пакеты
# и сегменты ClientHello приходят задом наперёд) и сам возвращает его при
# выходе. Если он завершился аварийно, исходное значение осталось в метке.
TSO_MARK=/var/run/macws.tso
tso_restore() {
	local v=1
	[ -f "$TSO_MARK" ] && [ -z "$(macws_pid)" ] || return 0
	read -r v < "$TSO_MARK" || true
	sysctl -w net.inet.tcp.tso="${v:-1}" >/dev/null 2>&1 && rm -f "$TSO_MARK"
	return 0
}

port_busy() { lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }

# ----------------------------------------------------------------- команды --
cmd_list() {
	if [ "$(engine)" = macws ]; then
		msg "${C_B}движок macws${C_0}: стратегии — те же .bat файлы, что в Windows-сборке"
		bat_list | sed 's/^/   /'
		msg ""
		msg "запуск:   sudo ./macos/zapret.sh start \"general (ALT4).bat\"   (или просто ALT4)"
		msg "перебор:  sudo ./macos/zapret.sh test-bat"
	fi
	msg "${C_B}движок tpws${C_0}: стратегии из macos/strategies.conf"
	local n
	for n in $(strategy_names); do
		printf '   %-18s %s%s\n' "$n" "$(strategy_field "$n" 4)" \
			"$([ "$n" = "$STRATEGY" ] && printf ' %s[по умолчанию]%s' "$C_B" "$C_0")"
	done
}

cmd_selftest() {
	require_root
	[ -x "$MACWS" ] || die "macws не собран: ./macos/zapret.sh build"
	[ -n "$(macws_pid)" ] && die "сначала остановите обход: sudo $0 stop"
	pf_conf_patch || die "pf: не удалось подготовить $PF_CONF"
	pf_enable
	pf_ensure_anchor_active || warn "заворот, скорее всего, не заработает — см. выше"
	mkdir -p "$STATE_DIR"
	msg "${C_B}проверка бэкенда macws${C_0} (utun + инъекция пакетов, IPv4 и IPv6)"
	local log res v4 v6
	log="$(mktemp "${TMPDIR:-/tmp}/zapret-selftest.XXXXXX")"
	MACWS_SELFTEST=1 MACWS_PF_ANCHOR="$PF_ANCHOR_NAME" MACWS_UTUN_PEER="$UTUN_PEER" 		MACWS_UTUN_PEER6="$UTUN_PEER6" MACWS_SELFTEST_DNS6="$DNS6_PROBE" 		"$MACWS" --debug=1 2>&1 | tee "$log"
	res="$(grep '^SELFTEST_RESULT' "$log" | tail -1)"
	rm -f "$log"
	v4="$(printf '%s' "$res" | sed -nE 's/.*v4=([a-z]+).*/\1/p')"
	v6="$(printf '%s' "$res" | sed -nE 's/.*v6=([a-z]+).*/\1/p')"
	printf '%s' "$(printf '%s' "$res" | sed -nE 's/.*inject=([a-z]+).*/\1/p')" > "$STATE_DIR/macws-inject"
	pf_down

	msg ""
	if [ "$v4" = ok ]; then
		: > "$STATE_DIR/macws-ok"
		ok "IPv4: бэкенд macws работает — можно запускать стратегии из .bat"
	else
		rm -f "$STATE_DIR/macws-ok" "$STATE_DIR/macws-v6-ok"
		warn "IPv4: бэкенд macws не прошёл проверку. Останется движок tpws (ENGINE=tpws)."
		warn "Диагностика: sudo MACWS_SELFTEST=1 $MACWS --debug=2"
		return 1
	fi
	case "$v6" in
		ok)   : > "$STATE_DIR/macws-v6-ok"; ok "IPv6: работает — обход будет применяться и к IPv6" ;;
		none) rm -f "$STATE_DIR/macws-v6-ok"; msg "IPv6: маршрута в IPv6-интернет нет, заворот IPv6 выключен" ;;
		*)    rm -f "$STATE_DIR/macws-v6-ok"; warn "IPv6: не работает — обход останется только для IPv4 (подробности выше)" ;;
	esac
	msg "включить:  sudo ./macos/zapret.sh start ${STRATEGY_BAT}"
}

start_macws() {
	local bat args rules
	bat="$(bat_resolve "${1:-$STRATEGY_BAT}")" || die "не найдена стратегия .bat: ${1:-$STRATEGY_BAT} (см. $0 list)"
	msg "запускаю macws: стратегия ${C_B}$(basename "$bat")${C_0}"
	mkdir -p "$STATE_DIR"
	pf_rules_macws "$bat" > "$STATE_DIR/macws.pf"
	[ -s "$STATE_DIR/macws.pf" ] || die "не удалось собрать правила pf из $(basename "$bat")"
	args="$(bat_args "$bat")"
	[ -n "$args" ] || die "не удалось разобрать аргументы из $(basename "$bat")"
	pf_conf_patch || die "pf: не удалось подготовить $PF_CONF"
	pf_enable
	pf_ensure_anchor_active || warn "заворот, скорее всего, не заработает — см. выше"
	eval "set -- $args"
	local dbg=()
	[ -n "$ENGINE_LOG" ] && { : > "$ENGINE_LOG"; dbg=("--debug=@$ENGINE_LOG"); }
	MACWS_PF_RULES="$STATE_DIR/macws.pf" MACWS_PF_ANCHOR="$PF_ANCHOR_NAME" \
		MACWS_UTUN_PEER="$UTUN_PEER" MACWS_UTUN_PEER6="$UTUN_PEER6" MACWS_SELFTEST_DNS6="$DNS6_PROBE" \
		"$MACWS" --daemon "--pidfile=$PIDFILE_MACWS" "${dbg[@]+"${dbg[@]}"}" "$@" || die "macws не запустился"
	sleep 1
	[ -n "$(macws_pid)" ] || die "macws не запустился (лог: $LOG, проверьте sudo $0 selftest)"
	printf '%s' "$(basename "$bat")" > "$STATE_DIR/strategy"
	printf 'macws' > "$STATE_DIR/engine"
	pf_watch_start
	ok "zapret запущен: macws, $(basename "$bat")"
	msg "QUIC: $([ "$QUIC" = block ] && printf 'глушится (браузер пойдёт по TCP)' || printf 'фейки по стратегии')"
	if ipv6_macws_on; then msg "IPv6: заворачивается вместе с IPv4"
	elif [ "$IPV6" != 0 ] && ipv6_route_exists; then
		msg "IPv6: не заворачивается, поэтому заглушён на этих портах — трафик пойдёт по IPv4"
		msg "      чтобы обходить и IPv6: sudo $0 selftest"
	fi
	[ "$(cat "$STATE_DIR/macws-inject" 2>/dev/null)" = bpf ] || msg "обход НЕ действует для трафика самого root (raw-инъекция)"
	msg "если в браузере не грузится, а тесты проходят: перезапустите браузер, и попробуйте QUIC=block в macos/config"
}

start_tpws() {
	local strat="${1:-$STRATEGY}"
	build_args transparent "$strat"
	mkdir -p "$STATE_DIR"
	msg "запускаю tpws: стратегия ${C_B}$strat${C_0}"
	"$TPWS" --daemon "--pidfile=$PIDFILE" "${ARGS[@]}" || die "tpws не запустился"
	sleep 0.5
	[ -n "$(tpws_pid)" ] || die "tpws не запустился"
	printf '%s' "$strat" > "$STATE_DIR/strategy"
	printf 'tpws' > "$STATE_DIR/engine"
	pf_conf_patch || die "pf: не удалось подготовить $PF_CONF"
	pf_rules_tpws > "$PF_ANCHOR"
	pfctl -n -f "$PF_ANCHOR" >/dev/null 2>&1 || { pfctl -n -f "$PF_ANCHOR"; die "pf: ошибка в правилах $PF_ANCHOR"; }
	pfctl -qa "$PF_ANCHOR_NAME" -f "$PF_ANCHOR" || die "pf: не удалось загрузить anchor"
	pf_enable
	pf_ensure_anchor_active || warn "заворот, скорее всего, не заработает — см. выше"
	pf_watch_start
	ok "zapret запущен: tpws, $strat (порты $TCP_PORTS)"
	[ "$BLOCK_QUIC" = 1 ] && msg "QUIC (udp/443) заблокирован: tpws не умеет udp"
	msg "обход НЕ действует для трафика самого root (ограничение pf+tpws)"
}

# Сразу после запуска проверяем несколько целей от имени пользователя, чтобы
# не гадать, работает ли обход
verify_after_start() {
	local url n=0 ok_n=0 bad=()
	msg "проверяю цели..."
	for url in $(targets_list | head -5); do
		n=$((n+1))
		if curl_ok "$url" && bigch_ok "$url"; then ok_n=$((ok_n+1)); else bad+=("$(url_host "$url")"); fi
	done
	[ "$n" = 0 ] && return 0
	if [ "$ok_n" = "$n" ]; then
		ok "проверка: открываются все $n из $n — обход работает"
	elif [ "$ok_n" -gt 0 ]; then
		warn "проверка: открываются $ok_n из $n, не открываются: ${bad[*]}"
		warn "подберите стратегию: sudo $0 test-bat"
	else
		warn "проверка: ни одна цель не открылась — обход не действует"
		warn "смотрите: sudo $0 status$(debug_tools_on && printf '  и  sudo %s debug' "$0")"
	fi
	return 0
}

cmd_start() {
	require_root
	ensure_engine
	service_loaded && {
		service_stop
		msg "вернуть автозапуск после ручных запусков: sudo $0 install"
	}
	uplink_is_tunnel && {
		warn "трафик уходит в туннель (VPN) — обход сквозь него не нужен и будет мешать."
		warn "Выключите VPN. Сторож сам поднимет обход, когда туннель уйдёт."
	}
	engines_stop
	pfctl -qa "$PF_ANCHOR_NAME" -F all 2>/dev/null
	if [ "$(engine)" = macws ]; then start_macws "${1:-}"; else start_tpws "${1:-}"; fi
	verify_after_start
	msg "в браузере проверяйте после его перезапуска: он кэширует HTTP/3 и мёртвые соединения"
}

cmd_stop() {
	require_root
	service_stop
	pf_watch_stop
	pf_down
	engines_stop
	rm -f "$STATE_DIR/engine"
	ok "zapret остановлен"
}

cmd_restart() { cmd_stop >/dev/null; cmd_start "$@"; }

cmd_run() {
	# точка входа для launchd; $2=debug — на переднем плане с подробным логом
	require_root
	ensure_engine
	# отладочный запуск руками не должен воевать со службой
	[ "${2:-}" = debug ] && service_loaded && {
		service_stop
		msg "вернуть автозапуск потом: sudo $0 install"
	}
	engines_stop
	local child rc=0 dbg=()
	[ "${2:-}" = debug ] && {
		mkdir -p "$STATE_DIR"
		: > "$STATE_DIR/debug.log"
		dbg=("--debug=@$STATE_DIR/debug.log")
		export MACWS_WIRE_AUDIT=1
		msg "лог пишется в $STATE_DIR/debug.log — откройте сайт, затем Ctrl-C"
		msg "включена сверка с проводом: при остановке будет строка wire audit"
	}
	if [ "$(engine)" = macws ]; then
		local bat args
		bat="$(bat_resolve "${1:-$STRATEGY_BAT}")" || die "не найдена стратегия .bat: ${1:-$STRATEGY_BAT}"
		mkdir -p "$STATE_DIR"
		pf_rules_macws "$bat" > "$STATE_DIR/macws.pf"
		args="$(bat_args "$bat")"
		pf_conf_patch || die "pf: не удалось подготовить $PF_CONF"
		pf_enable
		pf_ensure_anchor_active || warn "заворот, скорее всего, не заработает — см. выше"
		printf '%s' "$(basename "$bat")" > "$STATE_DIR/strategy"
		printf 'macws' > "$STATE_DIR/engine"
		eval "set -- $args"
		MACWS_PF_RULES="$STATE_DIR/macws.pf" MACWS_PF_ANCHOR="$PF_ANCHOR_NAME" \
		MACWS_UTUN_PEER="$UTUN_PEER" MACWS_UTUN_PEER6="$UTUN_PEER6" MACWS_SELFTEST_DNS6="$DNS6_PROBE" \
			"$MACWS" "${dbg[@]+"${dbg[@]}"}" "$@" &
		child=$!
	else
		build_args transparent "${1:-$STRATEGY}"
		pf_conf_patch || die "pf: не удалось подготовить $PF_CONF"
		pf_rules_tpws > "$PF_ANCHOR"
		pfctl -qa "$PF_ANCHOR_NAME" -f "$PF_ANCHOR" || die "pf: не удалось загрузить anchor"
		pf_enable
		pf_ensure_anchor_active || warn "заворот, скорее всего, не заработает — см. выше"
		printf 'tpws' > "$STATE_DIR/engine"
		"$TPWS" "${dbg[@]+"${dbg[@]}"}" "${ARGS[@]}" &
		child=$!
	fi
	pf_watch_start
	trap 'kill $child 2>/dev/null' INT TERM
	wait $child || rc=$?
	pf_watch_stop
	pf_down
	exit $rc
}

cmd_status() {
	local pid strat eng
	eng="$(cat "$STATE_DIR/engine" 2>/dev/null || printf '%s' "$(engine) (не запущен)")"
	strat="$(cat "$STATE_DIR/strategy" 2>/dev/null || printf '%s' '-')"
	local n_macws; n_macws="$(pgrep -f "$MACWS " 2>/dev/null | grep -c . || true)"
	[ "${n_macws:-0}" -gt 1 ] && warn "запущено экземпляров macws: $n_macws — лишние мешают, остановите: sudo $0 stop"
	pid="$(macws_pid)"
	if [ -n "$pid" ]; then ok "macws: работает (pid $pid), стратегия $strat"
	else
		pid="$(tpws_pid)"
		if [ -n "$pid" ]; then ok "tpws: работает (pid $pid), стратегия $strat"
		else warn "движок не запущен"; fi
	fi
	msg "движок: $eng"
	local up; up="$(route -n get 8.8.8.8 2>/dev/null | awk '/interface:/{print $2;exit}')"
	if uplink_is_tunnel; then
		warn "трафик идёт через туннель ($up): обход приостановлен, проверять его сейчас бессмысленно"
	else
		msg "трафик идёт через $up"
	fi
	if [ "$(id -u)" = 0 ]; then
		if pfctl -s info 2>/dev/null | grep -q '^Status: Enabled'; then
			local n; n=$(( $(pfctl -a "$PF_ANCHOR_NAME" -s nat 2>/dev/null | grep -c .) + $(pfctl -a "$PF_ANCHOR_NAME" -s rules 2>/dev/null | grep -c .) ))
			if [ "$n" -gt 0 ]; then ok "pf: включён, правил zapret: $n"; else warn "pf: включён, но правил zapret нет"; fi
			if pf_anchor_active; then ok "pf: активный ruleset ссылается на anchor \"$PF_ANCHOR_NAME\""
			else warn "pf: активный ruleset НЕ ссылается на anchor \"$PF_ANCHOR_NAME\" — заворот не работает"; fi
		else warn "pf: выключен"; fi
		ifconfig 2>/dev/null | grep -q "^utun9[0-9]\|^utun1[0-5][0-9]" && msg "utun для macws: $(ifconfig 2>/dev/null | sed -nE 's/^(utun(9[0-9]|1[0-5][0-9])):.*/\1/p' | paste -sd, -)"
	else msg "pf: (для проверки правил нужен sudo)"; fi
	if [ -f "$PLIST" ]; then
		if service_loaded; then ok "автозапуск: установлен и загружен"
		else msg "автозапуск: установлен, но сейчас выгружен (вернуть: sudo $0 install)"; fi
	else msg "автозапуск: не установлен"; fi
	if [ -x "$MACWS" ]; then
		msg "macws: $MACWS$([ -f "$STATE_DIR/macws-ok" ] && printf ' (selftest пройден)')"
		pf_watch_running && msg "сторож pf: работает" || msg "сторож pf: не запущен"
		local tso; tso="$(sysctl -n net.inet.tcp.tso 2>/dev/null)"
		if [ -n "$(macws_pid)" ]; then
			if [ "$tso" = 0 ]; then msg "TSO:   выключен на время обхода (крупные пакеты не теряются в utun)"
			elif [ "$tso" = 1 ]; then warn "TSO включён при работающем обходе — крупные ClientHello будут теряться, перезапустите обход"; fi
		fi
		msg "IPSet: $IPSET_FILTER$([ "$IPSET_FILTER" = loaded ] && [ -s "$STATE_DIR/ipset-loaded.txt" ] && printf ' (%s сетей)' "$(grep -c . "$STATE_DIR/ipset-loaded.txt")")"
		if ipv6_macws_on; then msg "IPv6:  заворачивается"
		elif [ "$IPV6" = 0 ]; then msg "IPv6:  выключен в настройках"
		elif [ -f "$STATE_DIR/macws-v6-ok" ]; then msg "IPv6:  проверен, но маршрута сейчас нет"
		else msg "IPv6:  не заворачивается (нет маршрута или не прошёл selftest)"; fi
	else warn "macws не собран"; fi
	[ -x "$TPWS" ] && msg "tpws:  $TPWS" || warn "tpws не собран"
}

cmd_socks() {
	[ -x "$TPWS" ] || cmd_build
	local strat="${1:-$STRATEGY}"
	port_busy "$SOCKS_PORT" && die "порт $SOCKS_PORT занят (измените SOCKS_PORT в macos/config)"
	build_args socks "$strat"
	ok "SOCKS5 прокси: 127.0.0.1:$SOCKS_PORT, стратегия $strat (Ctrl+C — выход)"
	msg "проверка:  curl -sI --socks5-hostname 127.0.0.1:$SOCKS_PORT https://www.youtube.com | head -1"
	msg "система:   sudo networksetup -setsocksfirewallproxy Wi-Fi 127.0.0.1 $SOCKS_PORT"
	msg "выключить: sudo networksetup -setsocksfirewallproxystate Wi-Fi off"
	exec "$TPWS" "${ARGS[@]}"
}

targets_list() {
	local f="$TARGETS_FILE"
	[ -s "$f" ] || { printf '%s\n' https://discord.com https://www.youtube.com https://www.google.com; return; }
	tr -d '\r' < "$f" | sed -nE 's/^[A-Za-z0-9_]+[[:space:]]*=[[:space:]]*"(https:\/\/[^"]+)".*/\1/p'
}

# Проверять надо от имени обычного пользователя: трафик root в правилах pf
# может быть исключён (иначе петля), и проверка от root шла бы мимо обхода.
as_user() {
	if [ "$(id -u)" = 0 ] && [ -n "${SUDO_USER:-}" ]; then sudo -u "$SUDO_USER" -- "$@"
	elif [ "$(id -u)" = 0 ]; then sudo -u nobody -- "$@"
	else "$@"; fi
}

# Применяется ли к хосту стратегия, т.е. есть ли он в хостлистах
host_in_lists() {
	local h="$1" d f
	for f in list-general.txt list-general-user.txt list-google.txt list-google-user.txt; do
		[ -s "$LISTS_DIR/$f" ] || continue
		while IFS= read -r d; do
			[ -n "$d" ] || continue
			case "$h" in "$d"|*".$d") return 0 ;; esac
		done < <(tr -d '\r' < "$LISTS_DIR/$f" | sed -e 's/^\^//' -e 's/[#;].*$//' -e 's/[[:space:]]//g' -e '/^$/d')
	done
	return 1
}

url_host() { printf '%s' "$1" | sed -e 's|^[a-z]*://||' -e 's|/.*$||' -e 's|:.*$||'; }

# Адрес хоста системным резолвером: dscacheutil работает и при DoH, в отличие от dig
resolve_host() {
	dscacheutil -q host -a name "$1" 2>/dev/null | sed -nE 's/^ip_address: ([0-9.]+)$/\1/p' | head -1
}

curl_code_text() {
	case "$1" in
		0)  printf 'OK' ;;
		6)  printf 'имя не разрешается — подмена DNS или сломанный резолвер' ;;
		7)  printf 'соединение отвергнуто/недоступно — блокировка по IP' ;;
		28) printf 'таймаут — DPI режет соединение или адрес заблокирован' ;;
		35) printf 'обрыв на TLS-рукопожатии — характерно для DPI по SNI' ;;
		52|56) printf 'соединение сброшено (RST) — характерно для DPI' ;;
		*)  printf 'ошибка curl %s' "$1" ;;
	esac
}

# Почему цель не открылась: код возврата curl многое объясняет
curl_reason() {
	local rc=0
	as_user curl -s -o /dev/null -m "$TEST_TIMEOUT" "$1" || rc=$?
	curl_code_text "$rc"
}

# Проба «как браузер»: ClientHello ~1900 байт не влезает в один сегмент, и DPI
# ведёт себя иначе, чем с коротким запросом curl. Именно это ломало браузер при
# зелёных тестах curl.
# Браузерная проба: настоящее TLS-рукопожатие системным стеком Apple (как у
# Safari), ClientHello 1538 байт в двух TCP-сегментах. Собирается тем же clang,
# что и движки, — ни Python, ни других языков не нужно
BIGCH="$BIN_DIR/bigch"
build_bigch() {
	command -v clang >/dev/null || { warn "нет clang — браузерная проба не собрана (xcode-select --install)"; return 1; }
	as_user clang -O2 -fblocks "$SRC_DIR/bigch.c" -framework Network -framework Security -o "$BIGCH" 2>/dev/null ||
		{ warn "браузерная проба не собралась — тесты пойдут только по curl"; return 1; }
	ok "bigch: браузерная проба собрана"
}
bigch_available() { [ -x "$BIGCH" ] || build_bigch >/dev/null 2>&1; [ -x "$BIGCH" ]; }
bigch_ok() {
	bigch_available || return 0
	as_user "$BIGCH" "$(url_host "$1")" 443 "$BIGCH_SIZE" "$TEST_TIMEOUT" >/dev/null 2>&1
}

curl_ok() {
	if [ -n "${2:-}" ]; then as_user curl -s -o /dev/null -m "$TEST_TIMEOUT" --socks5-hostname "$2" "$1"
	else as_user curl -s -o /dev/null -m "$TEST_TIMEOUT" "$1"; fi
}

TEST_PID=
test_cleanup() { [ -n "$TEST_PID" ] && kill "$TEST_PID" 2>/dev/null; TEST_PID=; }

cmd_test() {
	[ -x "$TPWS" ] || cmd_build
	local strats url s ok_n total best= best_n=-1 force=0 blocked=()
	while [ $# -gt 0 ]; do
		case "$1" in --force|-f) force=1; shift ;; *) break ;; esac
	done
	if [ $# -gt 0 ]; then strats="$*"; else strats="$(strategy_names | grep -vx none)"; fi
	port_busy "$TEST_PORT" && die "порт $TEST_PORT занят (измените TEST_PORT в macos/config)"
	trap 'test_cleanup; exit 130' INT TERM
	trap test_cleanup EXIT

	msg "${C_B}1) проверка без обхода${C_0} (таймаут ${TEST_TIMEOUT}s)"
	for url in $(targets_list); do
		local why; why="$(curl_reason "$url")"
		if [ "$why" = OK ]; then printf '   %-42s %sOK%s\n' "$url" "$C_G" "$C_0"
		else printf '   %-42s %s%s%s\n' "$url" "$C_R" "$why" "$C_0"; blocked+=("$url"); fi
	done
	[ ${#blocked[@]} = 0 ] && {
		ok "все цели открываются напрямую — обход не нужен (или блокировка по DNS: включите DoH)"
		[ "$force" = 1 ] || return 0
		msg "--force: проверяю стратегии на всех целях"
		for url in $(targets_list); do blocked+=("$url"); done
	}

	msg ""
	if [ "$force" = 1 ]; then msg "${C_B}2) перебор стратегий tpws${C_0} на ${#blocked[@]} целях"
	else msg "${C_B}2) перебор стратегий tpws${C_0} на ${#blocked[@]} заблокированных целях"; fi
	for s in $strats; do
		strategy_exists "$s" || { warn "нет такой стратегии: $s"; continue; }
		build_args test "$s" "$TEST_PORT"
		"$TPWS" "${ARGS[@]}" >/dev/null 2>&1 &
		TEST_PID=$!
		local i=0
		while [ $i -lt 20 ] && ! port_busy "$TEST_PORT"; do sleep 0.1; i=$((i+1)); done
		port_busy "$TEST_PORT" || warn "tpws не поднялся на порту $TEST_PORT (стратегия $s)"
		ok_n=0; total=0
		for url in "${blocked[@]}"; do
			total=$((total+1))
			curl_ok "$url" "127.0.0.1:$TEST_PORT" && ok_n=$((ok_n+1))
		done
		test_cleanup; wait 2>/dev/null
		if [ "$ok_n" = "$total" ]; then printf '   %-18s %s%s/%s%s\n' "$s" "$C_G" "$ok_n" "$total" "$C_0"
		elif [ "$ok_n" -gt 0 ]; then printf '   %-18s %s%s/%s%s\n' "$s" "$C_Y" "$ok_n" "$total" "$C_0"
		else printf '   %-18s %s%s/%s%s\n' "$s" "$C_R" "$ok_n" "$total" "$C_0"; fi
		[ "$ok_n" -gt "$best_n" ] && { best_n=$ok_n; best=$s; }
	done

	msg ""
	if [ "$best_n" -le 0 ]; then
		warn "ни одна стратегия tpws не помогла. Попробуйте полноценный движок: sudo $0 selftest && sudo $0 test-bat"
		return 1
	fi
	ok "лучшая стратегия tpws: $best ($best_n из ${#blocked[@]})"
	msg "включить:     sudo ./macos/zapret.sh start $best   (при ENGINE=tpws)"
	msg "по умолчанию: STRATEGY=$best в macos/config"
}

# перебор .bat стратегий на живом движке macws (нужен root)
# «браузер 8/8, curl 7/8» — или только curl, если браузерной пробы нет
score_text() {
	if bigch_available; then printf 'браузер %s/%s, curl %s/%s' "$1" "$3" "$2" "$3"
	else printf 'curl %s/%s' "$2" "$3"; fi
}

cmd_test_bat() {
	require_root
	[ -x "$MACWS" ] || cmd_build
	local bats url b bat ok_n total force=0 control= blocked=() failed=()
	local best= best_n=-1 best_failed= any= any_n=-1 broke=0 best_big=0 best_curl=0 any_big=0 any_curl=0
	while [ $# -gt 0 ]; do
		case "$1" in --force|-f) force=1; shift ;; *) break ;; esac
	done
	if [ $# -gt 0 ]; then bats="$*"; else bats="$(bat_list | tr '\n' '|')"; fi
	# подробный лог движка пишется только в отладочном режиме: он тяжёлый и
	# нужен лишь для разбора, вмешивался ли движок
	ENGINE_LOG=""
	debug_tools_on && ENGINE_LOG="$STATE_DIR/engine.log"
	local suspect="$STATE_DIR/engine-suspect.log" saved=0
	# перебор поднимает и гасит движок на каждой стратегии, поэтому работающий
	# обход придётся остановить. Запомним, что было, и вернём в конце
	local was_running= was_strategy=
	[ -n "$(macws_pid)$(tpws_pid)" ] && {
		was_running=1
		was_strategy="$(cat "$STATE_DIR/strategy" 2>/dev/null)"
		warn "обход сейчас работает — на время перебора он будет остановлен, в конце верну"
	}

	msg "${C_B}1) проверка без обхода${C_0}"
	engines_stop; pf_down >/dev/null
	local dns_bad=0 bigblocked=() rank_by_big=0
	for url in $(targets_list); do
		local why big=""; why="$(curl_reason "$url")"
		if bigch_available; then
			if bigch_ok "$url"; then big="  ${C_G}браузерная проба ОК${C_0}"
			else big="  ${C_R}браузерная проба режется${C_0}"; bigblocked+=("$url"); fi
		fi
		if [ "$why" = OK ]; then
			printf '   %-42s %sOK%s%s\n' "$url" "$C_G" "$C_0" "$big"
			# контроль должен быть из хостлистов, иначе стратегия к нему не
			# применяется и проверка ничего не значит
			if host_in_lists "$(url_host "$url")"; then control="$url"
			elif [ -z "$control" ]; then control="$url"; fi
		else
			printf '   %-42s %s%s%s%s\n' "$url" "$C_R" "$why" "$C_0" "$big"
			blocked+=("$url")
			case "$why" in "DNS не разрешается"*) dns_bad=$((dns_bad+1)) ;; esac
		fi
	done
	# лучшая выбирается по браузеру, а при равенстве — по curl
	if bigch_available; then
		rank_by_big=1
		[ ${#bigblocked[@]} -gt 0 ] ||
			msg "${C_D}браузерная проба без обхода не режется — стратегии различит в основном curl${C_0}"
	else
		warn "браузерная проба недоступна — выбираю только по curl"
	fi
	[ "$dns_bad" -gt 0 ] && {
		warn "у $dns_bad цели(ей) не разрешается DNS — это подмена DNS, а не DPI."
		warn "Включите DoH (Secure DNS) в браузере/системе, иначе никакая стратегия не поможет."
	}
	[ ${#blocked[@]} = 0 ] && {
		ok "все цели открываются напрямую"
		[ "$force" = 1 ] || { msg "перебрать всё равно: sudo $0 test-bat --force"; return 0; }
		for url in $(targets_list); do blocked+=("$url"); done
	}

	msg ""
	[ -n "$control" ] && {
		if host_in_lists "$(url_host "$control")"; then
			msg "${C_D}контроль: $(url_host "$control") — он в хостлистах, значит стратегия к нему применяется${C_0}"
		else
			warn "контроль $(url_host "$control") не входит в хостлисты: он проверит только сквозной пропуск"
		fi
	}
	bigch_available && msg "${C_D}curl — маленький ClientHello в одном пакете; браузер — настоящее рукопожатие как у Safari/Chrome (1538 байт, два пакета)${C_0}"
	msg "${C_B}2) перебор .bat стратегий${C_0} на ${#blocked[@]} целях (движок macws)"
	local IFS='|'
	for b in $bats; do
		unset IFS
		[ -n "$b" ] || continue
		bat="$(bat_resolve "$b")" || { warn "не найдено: $b"; continue; }
		ok_n=0; total=${#blocked[@]}; broke=0; failed=(); big_n=0
		if start_macws "$(basename "$bat")" >"$STATE_DIR/test-bat.log" 2>&1; then
			# контроль: цель, которая работала без обхода. Её поломка — не повод
			# не мерить остальное: стратегия может лечить одно и ломать другое
			if [ -n "$control" ] && ! curl_ok "$control" && { sleep 1; ! curl_ok "$control"; }; then broke=1; fi
			ok_n=0; total=0; big_n=0
			for url in "${blocked[@]}"; do
				local c=0 b=0
				total=$((total+1))
				curl_ok "$url" && { ok_n=$((ok_n+1)); c=1; }
				if bigch_available; then bigch_ok "$url" && { big_n=$((big_n+1)); b=1; }; else b=1; fi
				# в скобках — какая проба не прошла, если не прошла только одна
				case "$c$b" in
					00) failed+=("$(url_host "$url")") ;;
					10) failed+=("$(url_host "$url")(браузер)") ;;
					01) failed+=("$(url_host "$url")(curl)") ;;
				esac
			done
		else
			warn "не удалось запустить $(basename "$bat") (лог: $STATE_DIR/test-bat.log)"
		fi
		# движок обязан быть жив к концу проверки, иначе мерили пустоту
		local alive=1 touched=1
		[ -n "$(macws_pid)" ] || alive=0
		[ -n "$ENGINE_LOG" ] && ! grep -q "dpi desync " "$ENGINE_LOG" 2>/dev/null && touched=0
		engines_stop; pfctl -qa "$PF_ANCHOR_NAME" -F all 2>/dev/null

		local mark="" col="$C_R" bigtxt=""
		[ "$alive" = 0 ] && mark="$mark  ${C_R}(движок завершился)${C_0}"
		[ "$touched" = 0 ] && mark="$mark  ${C_Y}(движок не вмешивался)${C_0}"
		[ -n "$ENGINE_LOG" ] && [ "$ok_n" = 0 ] && [ "$saved" = 0 ] && { cp -f "$ENGINE_LOG" "$suspect" 2>/dev/null && saved=1; }
		[ "$broke" = 1 ] && mark="$mark  ${C_R}(ломает $(url_host "$control"))${C_0}"
		[ "$ok_n" -gt 0 ] && col="$C_Y"
		[ "$ok_n" = "$total" ] && col="$C_G"
		bigch_available && bigtxt="$(printf '  браузер %s%s/%s%s' "$([ "$big_n" = "$total" ] && printf '%s' "$C_G" || { [ "$big_n" -gt 0 ] && printf '%s' "$C_Y" || printf '%s' "$C_R"; })" "$big_n" "$total" "$C_0")"
		printf '   %-34s curl %s%s/%s%s%s%s\n' "$(basename "$bat")" "$col" "$ok_n" "$total" "$C_0" "$bigtxt" "$mark"

		# лучшая — среди тех, что не ломают контроль; отдельно лучшая вообще.
		# Главное — браузер (он и есть реальная работа), curl решает при равенстве:
		# 8/8 в браузере и 6/8 в curl лучше, чем 7/8 и 8/8
		local score="$ok_n"
		[ "$rank_by_big" = 1 ] && score=$(( big_n * 100 + ok_n ))
		if [ "$broke" = 0 ] && [ "$score" -gt "$best_n" ]; then
			best_n=$score; best="$(basename "$bat")"; best_big=$big_n; best_curl=$ok_n
			best_failed="$(printf '%s ' "${failed[@]+"${failed[@]}"}")"
		fi
		[ "$score" -gt "$any_n" ] && { any_n=$score; any="$(basename "$bat")"; any_big=$big_n; any_curl=$ok_n; }
		local IFS='|'
	done
	unset IFS
	pf_down >/dev/null

	msg ""
	restore_after_test() {
		# вернуть обход, если он работал до перебора
		[ -n "$was_running" ] || {
			warn "ОБХОД СЕЙЧАС ВЫКЛЮЧЕН: перебор останавливает движок."
			[ "$best_n" -gt 0 ] && msg "включить: sudo $0 start \"$best\""
			return 0
		}
		local st="${was_strategy:-$STRATEGY_BAT}"
		[ "$best_n" -gt 0 ] && st="$best"
		msg ""
		msg "возвращаю обход: $st"
		ENGINE_LOG=""   # рабочий обход — без подробного лога
		if [ "$(engine)" = macws ]; then start_macws "$st"; else start_tpws "$st"; fi
	}

	if [ "$best_n" -le 0 ] && [ "$any_n" -le 0 ]; then
		warn "ни одна стратегия не помогла"
		[ "$saved" = 1 ] && {
			warn "лог движка первой неудачной стратегии: $suspect"
			grep -E "cannot|error|failed|pf: |inject: |exiting" "$suspect" 2>/dev/null | head -8 | sed 's/^/   /'
		}
		warn "что дальше: ./macos/zapret.sh diag$(debug_tools_on && printf '  и  sudo ./macos/zapret.sh trace general.bat')"
		restore_after_test
		return 1
	fi
	if [ "$best_n" -gt 0 ]; then
		ok "лучшая стратегия: $best ($(score_text "$best_big" "$best_curl" ${#blocked[@]}), ничего не ломает)"
		[ -n "$best_failed" ] && msg "не вылечены: $best_failed"
	else
		warn "все помогающие стратегии ломают контрольную цель"
	fi
	[ "$any_n" -gt "$best_n" ] && msg "${C_Y}$any даёт больше ($(score_text "$any_big" "$any_curl" ${#blocked[@]})), но ломает $(url_host "$control")${C_0}"
	# профили в .bat ссылаются на ipset-all.txt; в репозитории он заглушка
	[ "$IPSET_FILTER" = none ] && msg "если часть целей ходит по ip без имени, попробуйте IPSET_FILTER=loaded в macos/config (осторожно: меняет поведение всех стратегий)"
	[ "$best_n" -gt 0 ] && {
		msg "в автозапуск: sudo ./macos/zapret.sh install \"$best\""
		msg "по умолчанию: STRATEGY_BAT=\"$best\" в macos/config"
	}
	restore_after_test
	return 0
}

cmd_check() {
	require_root
	ensure_engine
	local eng tmp save="$PF_ANCHOR" out rc=0
	eng="$(engine)"
	tmp="$(mktemp "${TMPDIR:-/tmp}/zapret-anchor.XXXXXX")"
	msg "${C_B}движок${C_0}: $eng"
	if [ "$eng" = macws ]; then
		local bat; bat="$(bat_resolve "${1:-$STRATEGY_BAT}")" || die "не найдена стратегия: ${1:-$STRATEGY_BAT}"
		msg "${C_B}стратегия${C_0}: $(basename "$bat")"
		# %UTUN% заменяем на реальное имя только при запуске; для проверки берём utun0
		pf_rules_macws "$bat" | sed 's/%UTUN%/utun0/' > "$tmp"
	else
		msg "${C_B}стратегия${C_0}: ${1:-$STRATEGY}"
		pf_rules_tpws > "$tmp"
	fi
	msg "${C_B}правила pf${C_0}:"
	sed 's/^/   /' "$tmp"
	out="$(pfctl -n -f "$tmp" 2>&1)" || rc=$?
	rm -f "$tmp"
	[ "$rc" = 0 ] || {
		printf '%s\n' "$out" | grep -v 'Use of -f option\|present in the main ruleset\|See /etc/pf.conf' >&2
		die "pf: правила не приняты"
	}
	ok "pf: синтаксис правил в порядке"
	if [ "$eng" = macws ]; then
		local bat args; bat="$(bat_resolve "${1:-$STRATEGY_BAT}")"; args="$(bat_args "$bat")"
		eval "set -- $args"
		"$MACWS" "$@" --dry-run >/dev/null || die "macws: параметры не приняты"
		ok "macws: параметры стратегии в порядке"
		[ -f "$STATE_DIR/macws-ok" ] || warn "бэкенд macws ещё не проверен: sudo $0 selftest"
	else
		build_args transparent "${1:-$STRATEGY}"
		"$TPWS" "${ARGS[@]}" --dry-run >/dev/null || die "tpws: параметры не приняты"
		ok "tpws: параметры стратегии в порядке"
	fi
}

# Что именно мешает цели: DNS, IP или DPI по имени. sudo не нужен.
cmd_diag() {
	local url host ip tcp_ok sni_ok nosni_ok verdict n_sni=0 n_ip=0 n_dns=0
	msg "${C_B}Что именно блокирует${C_0} (без обхода, таймаут ${TEST_TIMEOUT}s)"
	msg "${C_D}хост -> DNS -> TCP:443 -> TLS с SNI -> TLS без SNI (по IP)${C_0}"
	for url in $(targets_list); do
		host="$(url_host "$url")"
		ip="$(resolve_host "$host")"
		if [ -z "$ip" ]; then
			printf '   %-34s %sимя не разрешается — подмена DNS или сломанный резолвер%s\n' "$host" "$C_R" "$C_0"
			n_dns=$((n_dns+1)); continue
		fi
		nc -z -G 4 "$ip" 443 >/dev/null 2>&1 && tcp_ok=1 || tcp_ok=0
		as_user curl -s -o /dev/null -k -m "$TEST_TIMEOUT" "https://$host/" && sni_ok=1 || sni_ok=0
		as_user curl -s -o /dev/null -k -m "$TEST_TIMEOUT" "https://$ip/" && nosni_ok=1 || nosni_ok=0
		if [ "$sni_ok" = 1 ]; then verdict="${C_G}открывается${C_0}"
		elif [ "$tcp_ok" = 0 ]; then verdict="${C_R}TCP не устанавливается — блокировка по IP, обход DPI не поможет${C_0}"; n_ip=$((n_ip+1))
		elif [ "$nosni_ok" = 1 ]; then verdict="${C_Y}рвётся только с SNI — DPI по имени, лечится стратегией${C_0}"; n_sni=$((n_sni+1))
		else verdict="${C_R}TCP есть, но TLS не проходит и без SNI — блокировка по IP/на уровне данных${C_0}"; n_ip=$((n_ip+1)); fi
		printf '   %-34s %-15s %s\n' "$host" "$ip" "$verdict"
		[ "$sni_ok" = 0 ] && host_in_lists "$host" || true
	done
	msg ""
	[ "$n_sni" -gt 0 ] && ok "$n_sni цель(и) блокируются по SNI — их можно обойти: sudo $0 test-bat"
	[ "$n_ip" -gt 0 ] && warn "$n_ip цель(и) заблокированы по IP — ни одна стратегия zapret тут не поможет (нужен VPN/прокси)"
	[ "$n_dns" -gt 0 ] && warn "$n_dns цель(и) не разрешаются по имени — проверьте DNS/DoH"
	return 0
}

# Подробный разбор одного соединения: движок на переднем плане с полным логом
cmd_trace() {
	require_root
	ensure_engine
	[ "$(engine)" = macws ] || die "trace работает только с движком macws"
	local strat="${1:-$STRATEGY_BAT}" url="${2:-https://www.gstatic.com}"
	local bat args log child rc=0 ok_n fail_n
	bat="$(bat_resolve "$strat")" || die "не найдена стратегия: $strat"
	log="$STATE_DIR/trace.log"
	mkdir -p "$STATE_DIR"; : > "$log"

	msg "${C_B}стратегия${C_0}: $(basename "$bat")   ${C_B}цель${C_0}: $url"
	host_in_lists "$(url_host "$url")" \
		&& msg "${C_D}$(url_host "$url") есть в хостлистах — стратегия к нему применяется${C_0}" \
		|| warn "$(url_host "$url") НЕ в хостлистах — движок его не тронет, возьмите другой адрес"

	engines_stop
	pfctl -qa "$PF_ANCHOR_NAME" -F all 2>/dev/null
	pf_rules_macws "$bat" > "$STATE_DIR/macws.pf"
	args="$(bat_args "$bat")"
	pf_conf_patch || die "pf: не удалось подготовить $PF_CONF"
	pf_enable
	pf_ensure_anchor_active || warn "заворот, скорее всего, не заработает — см. выше"
	eval "set -- $args"
	MACWS_PF_RULES="$STATE_DIR/macws.pf" MACWS_PF_ANCHOR="$PF_ANCHOR_NAME" \
	MACWS_UTUN_PEER="$UTUN_PEER" MACWS_UTUN_PEER6="$UTUN_PEER6" MACWS_SELFTEST_DNS6="$DNS6_PROBE" \
		"$MACWS" "--debug=@$log" "$@" &
	child=$!
	sleep 2

	msg ""
	msg "${C_B}запрос через движок${C_0}"
	as_user curl -s -o /dev/null -m 12 -w '   curl: код %{http_code}, время %{time_total}s\n' "$url" || rc=$?
	[ "$rc" != 0 ] && warn "   curl не смог: $(curl_code_text "$rc")"
	sleep 1

	kill "$child" 2>/dev/null; wait "$child" 2>/dev/null
	pf_down >/dev/null

	msg ""
	msg "${C_B}что делал движок${C_0} (полный лог: $log)"
	grep -E "hostname:|desync profile [0-9]+ matches|^sending |^dpi desync |multisplit pos|seqovl :|packet: id=[0-9]+ (drop|send)|cannot|error" "$log" 2>/dev/null | tail -25

	local ch retr
	ch="$(grep -c 'contains full TLS ClientHello' "$log" 2>/dev/null || true)"
	retr="${ch:-0}"
	msg ""
	msg "${C_B}итог${C_0}"
	if grep -q "hostname: " "$log" 2>/dev/null; then ok "   имя из SNI распознано, стратегия применилась"
	else warn "   имя из SNI не распозналось — стратегия не применялась"; fi
	grep -E "^inject: [0-9]+ packets sent" "$log" 2>/dev/null | sed 's/^/   /'
	if [ "$retr" -gt 2 ]; then
		warn "   ClientHello отправлялся $retr раз(а) — сервер не подтверждает наши пакеты,"
		warn "   то есть они не доходят (сумма, кадр, маршрут) либо их режет DPI"
	elif [ "$retr" -gt 0 ]; then
		ok "   ClientHello отправлен $retr раз(а) — без шторма ретрансмитов"
	fi
	[ "$rc" = 0 ] && ok "   соединение прошло" || warn "   соединение не прошло: $(curl_code_text "$rc")"
	return 0
}

# Разбор лога движка: что он видел и что делал. sudo не нужен.
cmd_logsum() {
	local log="${1:-$STATE_DIR/debug.log}"
	[ -s "$log" ] || die "нет лога: $log (снимите: sudo $0 debug)"
	msg "${C_B}лог${C_0}: $log ($(grep -c . "$log") строк)"

	msg ""
	msg "${C_B}хосты, которые движок распознал${C_0} (SNI/Host)"
	grep -oE "hostname='[^']+'" "$log" | sed "s/hostname='//; s/'//" | sort | uniq -c | sort -rn | head -15 | sed 's/^/   /'
	grep -q "hostname='" "$log" || msg "   ${C_R}ни одного — значит имя не извлекается (ECH? шифрованный SNI?)${C_0}"

	msg ""
	msg "${C_B}что применялось${C_0}"
	grep -oE "^(sending|dpi desync)[^:]*" "$log" | sed -E 's/ src=.*//; s/ [0-9]+-[0-9]+.*//' | sort | uniq -c | sort -rn | head -12 | sed 's/^/   /'

	msg ""
	msg "${C_B}профили, которые сработали${C_0}"
	grep -oE "desync profile [0-9]+ matches" "$log" | sort | uniq -c | sort -rn | head -10 | sed 's/^/   /'

	local ch reasm quic drops inj
	ch="$(grep -c 'contains full TLS ClientHello' "$log" 2>/dev/null || true)"
	reasm="$(grep -cE 'reasm|DELAY desync' "$log" 2>/dev/null || true)"
	quic="$(grep -ciE 'quic' "$log" 2>/dev/null || true)"
	drops="$(grep -c 'packet: id=[0-9]* drop' "$log" 2>/dev/null || true)"
	msg ""
	msg "${C_B}счётчики${C_0}"
	printf '   ClientHello целиком в пакете: %s\n' "${ch:-0}"
	printf '   упоминаний сборки из нескольких пакетов (reasm): %s\n' "${reasm:-0}"
	printf '   упоминаний QUIC: %s\n' "${quic:-0}"
	printf '   пакетов сброшено (нормально для сплита): %s\n' "${drops:-0}"
	inj="$(grep -E '^inject: [0-9]+ packets sent' "$log" | tail -1)"
	[ -n "$inj" ] && printf '   %s\n' "$inj"

	msg ""
	msg "${C_B}подозрительное${C_0}"
	grep -nE "cannot|error|failed|not an ipv|no ipv6 link|too large|overload|WARNING" "$log" | head -10 | sed 's/^/   /' \
		|| msg "   ничего"
	return 0
}

# Перебор параметров desync по одной цели браузерной пробой. Нужен, когда все
# готовые .bat упираются в потолок: у больших ClientHello (два TCP-сегмента)
# работают другие точки разрыва, чем у короткого запроса curl.
tune_matrix() {
	local B="$ROOT_DIR/bin"
	cat <<TUNE
multisplit pos=1|--dpi-desync=multisplit --dpi-desync-split-pos=1
multisplit pos=2|--dpi-desync=multisplit --dpi-desync-split-pos=2
multisplit sniext+1|--dpi-desync=multisplit --dpi-desync-split-pos=sniext+1
multisplit midsld|--dpi-desync=multisplit --dpi-desync-split-pos=midsld
multisplit 1,midsld,sniext+1|--dpi-desync=multisplit --dpi-desync-split-pos=1,midsld,sniext+1
multisplit во 2-м сегменте|--dpi-desync=multisplit --dpi-desync-split-pos=1500
multidisorder 1,midsld|--dpi-desync=multidisorder --dpi-desync-split-pos=1,midsld
multidisorder sniext+1|--dpi-desync=multidisorder --dpi-desync-split-pos=sniext+1
seqovl 681 pos=1|--dpi-desync=multisplit --dpi-desync-split-seqovl=681 --dpi-desync-split-pos=1 --dpi-desync-split-seqovl-pattern=$B/tls_clienthello_www_google_com.bin
seqovl 681 midsld|--dpi-desync=multisplit --dpi-desync-split-seqovl=681 --dpi-desync-split-pos=midsld --dpi-desync-split-seqovl-pattern=$B/tls_clienthello_www_google_com.bin
fake badseq|--dpi-desync=fake --dpi-desync-repeats=6 --dpi-desync-fooling=badseq --dpi-desync-fake-tls=$B/tls_clienthello_www_google_com.bin
fake ts|--dpi-desync=fake --dpi-desync-repeats=6 --dpi-desync-fooling=ts --dpi-desync-fake-tls=$B/tls_clienthello_www_google_com.bin
fake+multisplit badseq|--dpi-desync=fake,multisplit --dpi-desync-split-pos=1 --dpi-desync-repeats=6 --dpi-desync-fooling=badseq --dpi-desync-fake-tls=$B/tls_clienthello_www_google_com.bin
fake+multisplit midsld|--dpi-desync=fake,multisplit --dpi-desync-split-pos=midsld --dpi-desync-repeats=6 --dpi-desync-fooling=badseq --dpi-desync-fake-tls=$B/tls_clienthello_www_google_com.bin
fake+multidisorder|--dpi-desync=fake,multidisorder --dpi-desync-split-pos=1,midsld --dpi-desync-repeats=6 --dpi-desync-fooling=badseq --dpi-desync-fake-tls=$B/tls_clienthello_www_google_com.bin
fakedsplit badseq|--dpi-desync=fake,fakedsplit --dpi-desync-split-pos=1 --dpi-desync-repeats=6 --dpi-desync-fooling=badseq --dpi-desync-fakedsplit-pattern=0x00
fakeddisorder|--dpi-desync=fake,fakeddisorder --dpi-desync-split-pos=midsld --dpi-desync-repeats=6 --dpi-desync-fooling=badseq
syndata|--dpi-desync=syndata
syndata+multisplit|--dpi-desync=syndata,multisplit --dpi-desync-split-pos=1
fake ttl=3|--dpi-desync=fake --dpi-desync-repeats=6 --dpi-desync-ttl=3 --dpi-desync-fake-tls=$B/tls_clienthello_www_google_com.bin
fake badsum|--dpi-desync=fake --dpi-desync-repeats=6 --dpi-desync-fooling=badsum --dpi-desync-fake-tls=$B/tls_clienthello_www_google_com.bin
fake md5sig|--dpi-desync=fake --dpi-desync-repeats=6 --dpi-desync-fooling=md5sig --dpi-desync-fake-tls=$B/tls_clienthello_www_google_com.bin
fake datanoack|--dpi-desync=fake --dpi-desync-repeats=6 --dpi-desync-fooling=datanoack --dpi-desync-fake-tls=$B/tls_clienthello_www_google_com.bin
fake autottl|--dpi-desync=fake --dpi-desync-repeats=6 --dpi-desync-autottl --dpi-desync-fake-tls=$B/tls_clienthello_www_google_com.bin
fake autottl+split 1|--dpi-desync=fake,multisplit --dpi-desync-split-pos=1 --dpi-desync-repeats=6 --dpi-desync-autottl --dpi-desync-fake-tls=$B/tls_clienthello_www_google_com.bin
fake autottl+split midsld|--dpi-desync=fake,multisplit --dpi-desync-split-pos=midsld --dpi-desync-repeats=6 --dpi-desync-autottl --dpi-desync-fake-tls=$B/tls_clienthello_www_google_com.bin
fake autottl+multidisorder|--dpi-desync=fake,multidisorder --dpi-desync-split-pos=1,midsld --dpi-desync-repeats=6 --dpi-desync-autottl --dpi-desync-fake-tls=$B/tls_clienthello_www_google_com.bin
fake autottl 2-8|--dpi-desync=fake --dpi-desync-repeats=8 --dpi-desync-autottl=-1:2-8 --dpi-desync-fake-tls=$B/tls_clienthello_www_google_com.bin
dup autottl|--dup=2 --dup-autottl
dup autottl+split 1|--dup=2 --dup-autottl --dpi-desync=multisplit --dpi-desync-split-pos=1
dup datanoack|--dup=2 --dup-fooling=datanoack
dup ttl=4|--dup=2 --dup-ttl=4
split 1000,1500|--dpi-desync=multisplit --dpi-desync-split-pos=1000,1500
split midsld,1500|--dpi-desync=multisplit --dpi-desync-split-pos=midsld,1500
ipfrag2|--dpi-desync=ipfrag2
ipfrag2 pos=24|--dpi-desync=ipfrag2 --dpi-desync-ipfrag-pos-tcp=24
ipfrag2 pos=32|--dpi-desync=ipfrag2 --dpi-desync-ipfrag-pos-tcp=32
fake+ipfrag2 badseq|--dpi-desync=fake,ipfrag2 --dpi-desync-repeats=6 --dpi-desync-fooling=badseq --dpi-desync-fake-tls=$B/tls_clienthello_www_google_com.bin
fake+ipfrag2 autottl|--dpi-desync=fake,ipfrag2 --dpi-desync-repeats=6 --dpi-desync-autottl --dpi-desync-fake-tls=$B/tls_clienthello_www_google_com.bin
fake rnd+dupsid|--dpi-desync=fake --dpi-desync-repeats=6 --dpi-desync-fooling=badseq --dpi-desync-fake-tls-mod=rnd,dupsid --dpi-desync-fake-tls=$B/tls_clienthello_www_google_com.bin
fake rnd+split midsld|--dpi-desync=fake,multisplit --dpi-desync-split-pos=midsld --dpi-desync-repeats=6 --dpi-desync-fooling=badseq --dpi-desync-fake-tls-mod=rnd,dupsid --dpi-desync-fake-tls=$B/tls_clienthello_www_google_com.bin
seqovl disorder midsld|--dpi-desync=multidisorder --dpi-desync-split-seqovl=681 --dpi-desync-split-pos=midsld --dpi-desync-split-seqovl-pattern=$B/tls_clienthello_www_google_com.bin
seqovl disorder sniext+1|--dpi-desync=multidisorder --dpi-desync-split-seqovl=336 --dpi-desync-split-pos=sniext+1 --dpi-desync-split-seqovl-pattern=$B/tls_clienthello_www_google_com.bin
multisplit 5 точек|--dpi-desync=multisplit --dpi-desync-split-pos=1,midsld,sniext+1,1000,1400
wssize 1:6|--wssize=1:6
wssize+split midsld|--wssize=1:6 --dpi-desync=multisplit --dpi-desync-split-pos=midsld
TUNE
}

cmd_tune() {
	require_root
	ensure_engine
	[ "$(engine)" = macws ] || die "tune работает только с движком macws"
	bigch_available || die "браузерная проба не собрана: ./macos/zapret.sh build"
	local host="${1:-www.youtube.com}" line name opts ok_big ok_curl found=0
	host="$(url_host "$host")"

	uplink_is_tunnel && die "трафик уходит в туннель (VPN) — сначала отключите VPN"
	engines_stop
	pfctl -qa "$PF_ANCHOR_NAME" -F all 2>/dev/null
	msg "${C_B}подбор параметров для $host${C_0} (браузерной пробой)"
	if bigch_ok "https://$host"; then
		warn "$host сейчас открывается и без обхода — подбирать нечего"
		return 0
	fi

	# минимальные правила: только tcp 80/443 и глушение QUIC
	mkdir -p "$STATE_DIR"
	{
		echo "table <nozapret> persist file \"$(nozapret_file)\""
		echo "block return out quick inet proto udp from any to !<nozapret> port 443"
		echo "pass out quick route-to (%UTUN% $UTUN_PEER) inet proto tcp from any to !<nozapret> port {80,443}$(root_exclusion) no state"
	} > "$STATE_DIR/macws.pf"
	pf_conf_patch || die "pf: не удалось подготовить $PF_CONF"
	pf_enable
	pf_ensure_anchor_active || warn "заворот может не работать — см. выше"

	while IFS='|' read -r name opts; do
		[ -n "$name" ] || continue
		engines_stop
		: > "$STATE_DIR/tune.log"
		eval "set -- $opts"
		MACWS_PF_RULES="$STATE_DIR/macws.pf" MACWS_PF_ANCHOR="$PF_ANCHOR_NAME" \
		MACWS_UTUN_PEER="$UTUN_PEER" \
			"$MACWS" --daemon "--pidfile=$PIDFILE_MACWS" "--debug=@$STATE_DIR/tune.log" \
			--filter-tcp=80,443 "--hostlist-domains=$host" "$@" >/dev/null 2>&1
		sleep 1
		if [ -z "$(macws_pid)" ]; then
			printf '   %-30s %sне запустился%s\n' "$name" "$C_R" "$C_0"
			continue
		fi
		ok_big=нет; ok_curl=нет
		bigch_ok "https://$host" && { ok_big=ДА; found=1; }
		curl_ok "https://$host" && ok_curl=ДА
		local ttl="" rok rbad
		ttl="$(grep -oE "desync autottl: guessed [0-9]+" "$STATE_DIR/tune.log" 2>/dev/null | tail -1 | grep -oE "[0-9]+$")"
		[ -z "$ttl" ] && grep -q "could not guess" "$STATE_DIR/tune.log" 2>/dev/null && ttl="TTL не угадан"
		[ -n "$ttl" ] && ttl="ttl $ttl"
		read -r rok rbad <<EOR
$(reasm_stats "$STATE_DIR/tune.log")
EOR
		[ "$rbad" -gt 0 ] && ttl="$ttl  ${C_R}сборка сорвалась${C_0}"
		if [ "$ok_big" = ДА ]; then
			printf '   %-30s браузер %sДА%s   curl %-4s %s\n' "$name" "$C_G" "$C_0" "$ok_curl" "$ttl"
			msg "     ${C_D}$opts${C_0}"
		else
			printf '   %-30s браузер %sнет%s   curl %-4s %s\n' "$name" "$C_R" "$C_0" "$ok_curl" "$ttl"
		fi
	done <<EOF
$(tune_matrix)
EOF

	engines_stop
	pf_down >/dev/null
	msg ""
	if [ "$found" = 1 ]; then
		ok "есть рабочие наборы (отмечены «браузер ДА»)"
		msg "добавьте выбранный набор в свою стратегию или скажите мне — соберу .bat"
	else
		warn "ни один набор не пробил $host на большом ClientHello."
		warn "Вероятно, для этого хоста блокировка не по SNI: проверьте ./macos/zapret.sh diag"
	fi
	return 0
}

# Сколько пакетов ядро выбросило, не сумев их фрагментировать: так pf поступает
# с TSO-суперпакетами, которые route-to уводит в utun
cantfrag_count() {
	netstat -s -p ip 2>/dev/null | awk "/can't be fragmented/{print \$1; exit}"
}

# Итог сборки ClientHello из нескольких сегментов по логу движка: «удачных срыв»
reasm_stats() {
	awk '/now we have [0-9]+\/[0-9]+/{split($NF,a,"/"); if (a[1]==a[2]) ok++}
	     /reassemble session failed/{bad++}
	     END{printf "%d %d\n", ok+0, bad+0}' "$1" 2>/dev/null || echo "0 0"
}

# Пробы ClientHello разного вида: размер, наличие и содержимое SNI, адрес подключения
probe_ch() {   # probe_ch <хост> <размер> [ключи...]
	local h="$1" sz="$2"; shift 2
	as_user "$BIGCH" "$h" 443 "$sz" "$TEST_TIMEOUT" "$@" >/dev/null 2>&1
}

# Набор проб различающего опыта: описание|размер|ключи (%IP% подставляется)
why_matrix() {
	cat <<EOF
маленький ClientHello, SNI есть|0|--small
ClientHello ~1300 б, один сегмент, SNI есть|1300|--small
браузерный ClientHello, два сегмента|0|
браузерный, без SNI, по IP|0|--sni none --connect %IP%
браузерный, чужой SNI, по IP|0|--sni example.com --connect %IP%
EOF
}

# Различающий опыт по одной цели: за что цепляется DPI — за имя, за размер
# ClientHello или за разрыв его на два TCP-сегмента. Отвечает на вопрос,
# лечится ли цель стратегией вообще.
cmd_why() {
	require_root
	ensure_engine
	[ "$(engine)" = macws ] || die "why работает только с движком macws"
	bigch_available || die "браузерная проба не собрана: ./macos/zapret.sh build"
	local host="${1:-www.youtube.com}" strat="${2:-$STRATEGY_BAT}" ip bat
	local labels=() sizes=() flags=() off=() on=() i=0 n=0
	host="$(url_host "$host")"
	bat="$(bat_resolve "$strat")" || die "не найдена стратегия: $strat"
	uplink_is_tunnel && die "трафик уходит в туннель (VPN) — сначала отключите VPN"
	ip="$(resolve_host "$host")"
	[ -n "$ip" ] || die "$host не разрешается в адрес — это подмена DNS, а не DPI"
	ENGINE_LOG="$STATE_DIR/engine.log"   # чтобы увидеть, вмешивался ли движок

	local label size fl
	while IFS='|' read -r label size fl; do
		[ -n "$label" ] || continue
		labels[$n]="$label"; sizes[$n]="$size"
		flags[$n]="$(printf '%s' "$fl" | sed "s/%IP%/$ip/")"
		n=$((n+1))
	done <<EOF
$(why_matrix)
EOF

	msg "${C_B}за что цепляется DPI: $host${C_0} ($ip), стратегия $(basename "$bat")"
	msg "${C_D}каждая проба — настоящее TLS-рукопожатие; «ок» значит, что сервер ответил${C_0}"

	# опыт поднимает и гасит движок, поэтому работающий обход придётся тронуть
	local was_running= was_strategy=
	[ -n "$(macws_pid)$(tpws_pid)" ] && {
		was_running=1
		was_strategy="$(cat "$STATE_DIR/strategy" 2>/dev/null)"
		warn "обход сейчас работает — на время опыта остановлю его, в конце верну"
	}

	engines_stop; pf_down >/dev/null
	i=0; while [ "$i" -lt "$n" ]; do
		eval "set -- ${flags[$i]}"
		probe_ch "$host" "${sizes[$i]}" "$@" && off[$i]=1 || off[$i]=0
		i=$((i+1))
	done

	start_macws "$(basename "$bat")" >"$STATE_DIR/why.log" 2>&1 || warn "стратегия не запустилась (лог: $STATE_DIR/why.log)"
	local cf0 cf1; cf0="$(cantfrag_count)"
	i=0; while [ "$i" -lt "$n" ]; do
		eval "set -- ${flags[$i]}"
		probe_ch "$host" "${sizes[$i]}" "$@" && on[$i]=1 || on[$i]=0
		i=$((i+1))
	done
	cf1="$(cantfrag_count)"
	local touched=0 rok rbad
	grep -q "dpi desync " "$ENGINE_LOG" 2>/dev/null && touched=1
	read -r rok rbad <<EOF
$(reasm_stats "$ENGINE_LOG")
EOF
	engines_stop; pf_down >/dev/null

	why_restore() {
		[ -n "$was_running" ] || return 0
		msg ""
		msg "возвращаю обход: ${was_strategy:-$STRATEGY_BAT}"
		ENGINE_LOG=""
		if [ "$(engine)" = macws ]; then start_macws "${was_strategy:-$STRATEGY_BAT}"; else start_tpws "${was_strategy:-$STRATEGY_BAT}"; fi
	}

	msg ""
	printf '   %-44s %-12s %s\n' "проба" "без обхода" "с обходом"
	i=0; while [ "$i" -lt "$n" ]; do
		local a b
		[ "${off[$i]}" = 1 ] && a="${C_G}ок${C_0}" || a="${C_R}режется${C_0}"
		[ "${on[$i]}" = 1 ] && b="${C_G}ок${C_0}" || b="${C_R}режется${C_0}"
		printf '   %-44s %-21s %s\n' "${labels[$i]}" "$a" "$b"
		i=$((i+1))
	done
	msg ""
	[ "$touched" = 0 ] && warn "движок ни одного пакета не переделал — правила pf не заворачивают трафик, вывод ниже недостоверен"
	msg "${C_D}сборка ClientHello из сегментов: удачных $rok, сорвалось $rbad; ядро выбросило крупных пакетов: $(( ${cf1:-0} - ${cf0:-0} ))${C_0}"
	if [ "${rbad:-0}" -gt 0 ]; then
		warn "сборка ClientHello в движке срывалась — большой ClientHello уходил без обработки."
		warn "Это неполадка заворота, а не стратегии: пришлите вывод sudo $0 status"
	fi

	# разбор: сначала выясняем, по имени ли блокировка, потом — что лечит обход
	if [ "${off[2]}" = 1 ]; then
		ok "большой ClientHello проходит и без обхода: на уровне TLS этот хост не режется"
		msg "значит причина недогрузки в другом: QUIC, другие домены страницы или DNS"
		why_restore; return 0
	fi
	if [ "${off[3]}" = 0 ] && [ "${off[4]}" = 0 ]; then
		warn "большой ClientHello режется даже без SNI и с чужим SNI — цепляются не за имя,"
		warn "а за адрес или за сам вид соединения. Desync-стратегии тут бессильны:"
		warn "для этого хоста нужен прокси/VPN (./macos/zapret.sh socks) или ECH в браузере"
		why_restore; return 1
	fi
	ok "блокировка по имени в ClientHello — это лечится стратегией"
	if [ "${on[2]}" = 1 ]; then
		ok "стратегия $(basename "$bat") пробивает и большой ClientHello — цель должна работать в браузере"
		why_restore; return 0
	fi
	if [ "${on[1]}" = 1 ] || [ "${on[0]}" = 1 ]; then
		warn "обход лечит ClientHello в одном сегменте, но не разорванный на два:"
		warn "DPI собирает TCP-сегменты, поэтому расщепление его не обманывает"
		[ "${off[1]}" = 0 ] && msg "${C_D}(~1300 байт в одном сегменте режется и без обхода, значит дело не в размере, а в имени)${C_0}"
		msg "что делать: включить ECH в браузере (тогда имени в ClientHello нет вовсе),"
		msg "либо увести только этот хост в прокси: ./macos/zapret.sh socks"
		why_restore; return 1
	fi
	warn "обход не помог даже маленькому ClientHello — стратегия $(basename "$bat") для этой цели не подходит"
	msg "переберите другие: sudo $0 test-bat$(debug_tools_on && printf '   или подберите параметры: sudo %s tune %s' "$0" "$host")"
	why_restore; return 1
}

cmd_install() {
	require_root
	ensure_engine
	local strat eng; eng="$(engine)"
	if [ "$eng" = macws ]; then strat="${1:-$(cat "$STATE_DIR/strategy" 2>/dev/null || printf '%s' "$STRATEGY_BAT")}"
		bat_resolve "$strat" >/dev/null || die "не найдена стратегия: $strat"
		strat="$(basename "$(bat_resolve "$strat")")"
	else strat="${1:-$(cat "$STATE_DIR/strategy" 2>/dev/null || printf '%s' "$STRATEGY")}"
		strategy_exists "$strat" || die "неизвестная стратегия: $strat"
	fi
	engines_stop
	cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>zapret</string>
	<key>ProgramArguments</key>
	<array>
		<string>$SELF_DIR/zapret.sh</string>
		<string>_run</string>
		<string>$strat</string>
	</array>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><true/>
	<key>StandardOutPath</key><string>$LOG</string>
	<key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PLIST_EOF
	chown root:wheel "$PLIST"; chmod 644 "$PLIST"
	mkdir -p "$STATE_DIR"; printf '%s' "$strat" > "$STATE_DIR/strategy"
	launchctl bootout system/zapret 2>/dev/null
	launchctl bootstrap system "$PLIST" 2>/dev/null || launchctl load -w "$PLIST" || die "launchctl: не удалось загрузить $PLIST"
	sleep 2
	ok "автозапуск установлен: $eng, $strat (лог: $LOG)"
	msg "не переносите папку $ROOT_DIR — путь прописан в $PLIST"
	cmd_status
}

cmd_uninstall() {
	require_root
	launchctl bootout system/zapret 2>/dev/null || launchctl unload -w "$PLIST" 2>/dev/null
	rm -f "$PLIST"
	pf_watch_stop
	pf_down
	engines_stop
	pf_conf_unpatch
	rm -f "$STATE_DIR/engine"
	ok "автозапуск удалён, правила pf и патч $PF_CONF убраны"
}

cmd_update_ipset() {
	# Обновляем свою копию в .state, файлы репозитория не трогаем: подмена
	# ipset-all.txt меняет поведение ВСЕХ стратегий (профили по ipset матчатся
	# уже на SYN, до того как виден SNI, и перебивают профили по хостлистам)
	local f="$STATE_DIR/ipset-loaded.txt" tmp
	mkdir -p "$STATE_DIR"
	tmp="$(mktemp "${TMPDIR:-/tmp}/ipset.XXXXXX")"
	msg "скачиваю список адресов..."
	if curl -fsSL "$IPSET_URL" -o "$tmp" && [ -s "$tmp" ]; then
		mv -f "$tmp" "$f"; chmod 644 "$f"
		ok "обновлено: $f ($(grep -c . "$f") строк)"
	elif [ -s "$ROOT_DIR/.service/ipset-service.txt" ]; then
		rm -f "$tmp"
		tr -d '\r' < "$ROOT_DIR/.service/ipset-service.txt" > "$f"
		warn "сеть недоступна, взял локальную копию .service/ipset-service.txt ($(grep -c . "$f") строк)"
	else
		rm -f "$tmp"; die "не удалось обновить список"
	fi
	if [ "$IPSET_FILTER" = loaded ]; then
		{ [ -n "$(macws_pid)" ] || [ -n "$(tpws_pid)" ]; } && msg "перезапустите обход: sudo ./macos/zapret.sh restart"
	else
		msg "список подключится при IPSET_FILTER=loaded (сейчас $IPSET_FILTER)"
	fi
	return 0
}

cmd_args() {
	# отладка: показать командную строку движка
	if [ "$(engine)" = macws ]; then
		local bat; bat="$(bat_resolve "${1:-$STRATEGY_BAT}")" || die "не найдена стратегия: ${1:-$STRATEGY_BAT}"
		printf '%s ' "$MACWS"; bat_args "$bat"; echo
	else
		build_args "${2:-transparent}" "${1:-$STRATEGY}" "${3:-}"
		printf '%q ' "$TPWS" "${ARGS[@]}"; echo
	fi
}

usage() {
	cat <<USAGE_EOF
zapret для macOS. Движок: $(engine) (ENGINE=$ENGINE)

  ./macos/zapret.sh menu                  меню (то же, что двойной щелчок по macos/service.command)
  ./macos/zapret.sh build                 собрать движки (нужны Command Line Tools)
  ./macos/zapret.sh list                  стратегии
  sudo ./macos/zapret.sh selftest         проверить бэкенд macws (utun + инъекция)

  sudo ./macos/zapret.sh test-bat [--force] [.bat...]  перебрать .bat стратегии (macws)
       ./macos/zapret.sh test [--force] [стратегии...] перебрать стратегии tpws (без sudo)
       ./macos/zapret.sh socks [стратегия]            SOCKS5 tpws на 127.0.0.1:$SOCKS_PORT

  sudo ./macos/zapret.sh start [стратегия]   включить обход
  sudo ./macos/zapret.sh stop
  sudo ./macos/zapret.sh restart [стратегия]
       ./macos/zapret.sh status

  sudo ./macos/zapret.sh install [стратегия] автозапуск (launchd)
  sudo ./macos/zapret.sh uninstall           убрать автозапуск и правила pf
       ./macos/zapret.sh diag                 что именно блокирует: DNS, IP или DPI по SNI
       ./macos/zapret.sh update-ipset        обновить список адресов для IPSET_FILTER=loaded

Стратегия macws по умолчанию: $STRATEGY_BAT, tpws: $STRATEGY
Настройки: macos/config (см. config.example). Что работает — macos/README.md
USAGE_EOF
	if debug_tools_on; then
		cat <<USAGE_EOF

Отладка (DEBUG_TOOLS=1):
  sudo ./macos/zapret.sh debug [стратегия]   движок на переднем плане с подробным логом
  sudo ./macos/zapret.sh check [стратегия]   показать правила pf и проверить параметры
  sudo ./macos/zapret.sh trace [стратегия] [url]  разобрать одно соединение по шагам
       ./macos/zapret.sh logsum [файл]       разбор лога движка (по умолчанию .state/debug.log)
  sudo ./macos/zapret.sh why [хост] [стратегия]   за что цепляется DPI у одной цели
       ./macos/zapret.sh bigch [хост] [размер]  браузерная проба вручную
  sudo ./macos/zapret.sh tune [хост]        перебрать параметры desync по одной цели
USAGE_EOF
	else
		msg ""
		msg "Отладочные команды (debug, check, trace, logsum, why, bigch, tune) выключены: DEBUG_TOOLS=1 в macos/config"
	fi
}

case "${1:-help}" in
	menu)         exec "$SELF_DIR/service.command" ;;
	build)        cmd_build ;;
	list)         cmd_list ;;
	selftest)     cmd_selftest ;;
	test)         shift; cmd_test "$@" ;;
	test-bat)     shift; cmd_test_bat "$@" ;;
	socks)        shift; cmd_socks "${1:-}" ;;
	check)        require_debug_tools check; shift; cmd_check "${1:-}" ;;
	start)        shift; cmd_start "${1:-}" ;;
	stop)         cmd_stop ;;
	restart)      shift; cmd_restart "${1:-}" ;;
	status)       cmd_status ;;
	install)      shift; cmd_install "${1:-}" ;;
	uninstall)    cmd_uninstall ;;
	diag)         cmd_diag ;;
	logsum)       require_debug_tools logsum; shift; cmd_logsum "${1:-}" ;;
	tune)         require_debug_tools tune; shift; cmd_tune "${1:-}" ;;
	why)          require_debug_tools why; shift; cmd_why "$@" ;;
	bigch)        require_debug_tools bigch; shift; bigch_available || die "браузерная проба не собрана: ./macos/zapret.sh build"
	              # лишние ключи (--small, --sni, --connect) передаём пробнику как есть
	              case "${1:-}" in
	              --selfcheck) shift; as_user "$BIGCH" --selfcheck "$BIGCH_SIZE" "$@" ;;
	              *)  BHOST="$(url_host "${1:-www.youtube.com}")"; BSIZE="${2:-$BIGCH_SIZE}"
	                  case "${1:-}" in -*) BHOST=www.youtube.com; BSIZE="$BIGCH_SIZE" ;; *) [ $# -gt 0 ] && shift ;; esac
	                  case "${1:-}" in -*) ;; *) [ $# -gt 0 ] && shift ;; esac
	                  as_user "$BIGCH" "$BHOST" 443 "$BSIZE" "$TEST_TIMEOUT" "$@" ;;
	              esac ;;
	trace)        require_debug_tools trace; shift; cmd_trace "${1:-}" "${2:-}" ;;
	update-ipset) cmd_update_ipset ;;
	_run)         shift; cmd_run "${1:-}" ;;
	debug)        require_debug_tools debug; shift; msg "движок на переднем плане, Ctrl-C — стоп"; cmd_run "${1:-}" debug ;;
	quic)         shift; msg "QUIC=$QUIC (fake — фейки по стратегии, block — глушить udp/443)" ;;
	_args)        shift; cmd_args "${1:-}" "${2:-}" "${3:-}" ;;
	help|-h|--help) usage ;;
	*)            usage; exit 1 ;;
esac
