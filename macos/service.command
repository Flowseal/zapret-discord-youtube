#!/bin/bash
#
# zapret для macOS — меню, аналог service.bat из Windows-сборки.
# Можно запускать двойным щелчком из Finder: macOS откроет его в Терминале.

set -u
cd "$(cd "$(dirname "$0")" && pwd)" || exit 1

Z="./zapret.sh"
CONFIG="./config"
EXAMPLE="./config.example"
ROOT_DIR="$(cd .. && pwd)"

[ -x "$Z" ] || { echo "нет $Z"; read -r _; exit 1; }

if [ -t 1 ]; then B=$'\033[1m'; D=$'\033[2m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'
else B=; D=; G=; Y=; R=; N=; fi

# ------------------------------------------------------------------ config --
cfg_get() {
	# $1 - ключ, $2 - значение по умолчанию
	local v=
	[ -f "$CONFIG" ] && v="$(sed -nE "s/^[[:space:]]*$1=[\"']?([^\"'#]*)[\"']?.*/\1/p" "$CONFIG" | tail -1)"
	v="${v%"${v##*[![:space:]]}"}"
	printf '%s' "${v:-$2}"
}

cfg_set() {
	# $1 - ключ, $2 - значение
	[ -f "$CONFIG" ] || {
		if [ -f "$EXAMPLE" ]; then cp "$EXAMPLE" "$CONFIG"
		else printf '# настройки zapret для macOS\n' > "$CONFIG"; fi
	}
	if grep -qE "^[[:space:]]*$1=" "$CONFIG"; then
		sed -i '' -E "s|^[[:space:]]*$1=.*|$1=\"$2\"|" "$CONFIG"
	else
		printf '%s="%s"\n' "$1" "$2" >> "$CONFIG"
	fi
	echo "${G}$1=$2${N}  (записано в macos/config)"
}

engine_now() {
	local e; e="$(cfg_get ENGINE auto)"
	case "$e" in
		macws|tpws) printf '%s' "$e" ;;
		*) if [ -x ./bin/macws ] && [ -f ./.state/macws-ok ]; then printf 'macws'; else printf 'tpws'; fi ;;
	esac
}

strategy_now() {
	if [ "$(engine_now)" = macws ]; then cfg_get STRATEGY_BAT general.bat; else cfg_get STRATEGY disorder; fi
}

pause() { printf '\n%s' "${D}Enter — назад в меню${N} "; read -r _; }

# отладочные пункты (их нет в оригинальном service.bat) — только при DEBUG_TOOLS=1
debug_on() { [ "$(cfg_get DEBUG_TOOLS 0)" = 1 ]; }

# ------------------------------------------------------------------- шапка --
header() {
	local eng strat pid auto gf
	eng="$(engine_now)"
	strat="$(strategy_now)"
	auto="$([ -f /Library/LaunchDaemons/zapret.plist ] && printf '%s' "${G}установлен${N}" || printf '%s' "нет")"
	gf="$(cfg_get GAME_FILTER off)"
	pid="$(pgrep -f "$ROOT_DIR/macos/bin/(macws|tpws) " 2>/dev/null | head -1)"

	clear 2>/dev/null || printf '\033[H\033[2J'
	printf '%s\n' "${B}══════════ zapret для macOS ══════════${N}"
	printf ' движок:      %s%s\n' "${B}$eng${N}" "$([ "$(cfg_get ENGINE auto)" = auto ] && printf ' %s(auto)%s' "$D" "$N")"
	printf ' стратегия:   %s\n' "${B}$strat${N}"
	if [ -n "$pid" ]; then printf ' обход:       %s (pid %s)\n' "${G}работает${N}" "$pid"
	else printf ' обход:       %s\n' "${Y}не запущен${N}"; fi
	printf ' автозапуск:  %s\n' "$auto"
	printf ' game filter: %s\n' "$gf"
	printf ' ipset:       %s\n' "$(cfg_get IPSET_FILTER none)"
	printf ' quic:        %s\n' "$(cfg_get QUIC block)"
	debug_on && printf ' отладка:     %s\n' "${Y}включена${N}"
	[ -x ./bin/macws ] || printf ' %s\n' "${Y}движки не собраны — пункт 12${N}"
	printf '%s\n' "${D}──────────────────────────────────────${N}"
}

menu() {
	cat <<'EOM'
  1. Включить обход
  2. Остановить
  3. Перезапустить
  4. Установить в автозапуск
  5. Убрать автозапуск

  6. Выбрать стратегию
  7. Подобрать стратегию (тесты)
  8. Проверить бэкенд macws (selftest)

  9. Переключить движок (macws / tpws / auto)
 10. Game Filter (off / tcp / udp / all)
 11. IPSet Filter (none / loaded / any)
 12. Собрать / обновить движки
 13. Диагностика: что блокирует + статус
 14. QUIC: фейки / глушить (если в браузере не грузится)
EOM
	debug_on && cat <<'EOM'

 15. Запустить с подробным логом (отладка)
 16. Почему сайт не открывается (разбор одной цели)
EOM
	echo "  0. Выход"
}

# ------------------------------------------------------------------ пункты --
choose_strategy() {
	local eng list n i=1 pick
	eng="$(engine_now)"
	echo "${B}Стратегии для движка $eng${N}"
	if [ "$eng" = macws ]; then
		list="$( (cd "$ROOT_DIR" && ls *.bat 2>/dev/null | grep -v '^service\.bat$') )"
	else
		list="$("$Z" list 2>/dev/null | awk '/движок tpws/{f=1;next} f&&NF{print $1}')"
	fi
	[ -n "$list" ] || { echo "${R}список пуст${N}"; return; }
	while IFS= read -r n; do printf '%3d. %s\n' "$i" "$n"; i=$((i+1)); done <<< "$list"
	printf '\n%s' "номер или имя (Enter — отмена): "
	read -r pick
	[ -z "$pick" ] && return
	case "$pick" in
		''|*[!0-9]*) n="$pick" ;;
		*) n="$(printf '%s\n' "$list" | sed -n "${pick}p")" ;;
	esac
	[ -n "$n" ] || { echo "${R}нет такой строки${N}"; return; }
	if [ "$eng" = macws ]; then cfg_set STRATEGY_BAT "$n"; else cfg_set STRATEGY "$n"; fi
	if pgrep -qf "$ROOT_DIR/macos/bin/(macws|tpws) " 2>/dev/null; then
		printf 'перезапустить обход с новой стратегией? [y/N] '
		read -r yn
		case "$yn" in [yYдД]*) sudo "$Z" restart "$n" ;; esac
	fi
}

toggle_engine() {
	local e; e="$(cfg_get ENGINE auto)"
	case "$e" in
		auto)  cfg_set ENGINE macws ;;
		macws) cfg_set ENGINE tpws ;;
		*)     cfg_set ENGINE auto ;;
	esac
	echo "${D}macws — полный движок (fake/seqovl/UDP), tpws — только TCP, auto — macws если прошёл selftest${N}"
}

toggle_quic() {
	local q; q="$(cfg_get QUIC block)"
	case "$q" in
		block) cfg_set QUIC fake ;;
		*)     cfg_set QUIC block ;;
	esac
	echo "${D}fake — движок подделывает QUIC по стратегии (как в Windows);"
	echo "block — udp/443 глушится, и браузер уходит на TCP, который уже обходится."
	echo "Помогает, когда тесты проходят, а в браузере сайт не грузится.${N}"
	echo "${D}после смены нужен перезапуск обхода (пункт 3) и браузера${N}"
}

toggle_ipset_filter() {
	local f; f="$(cfg_get IPSET_FILTER none)"
	case "$f" in
		none)   cfg_set IPSET_FILTER loaded; "$Z" update-ipset ;;
		loaded) cfg_set IPSET_FILTER any ;;
		*)      cfg_set IPSET_FILTER none ;;
	esac
	echo "${D}none — список не используется (так в Windows по умолчанию), loaded — полный список,"
	echo "any — под фильтр попадает любой адрес. Меняет поведение ВСЕХ стратегий,"
	echo "потому что профили по ipset срабатывают раньше профилей по хостлистам.${N}"
	echo "${D}после смены нужен перезапуск обхода (пункт 3)${N}"
}

toggle_game_filter() {
	local g; g="$(cfg_get GAME_FILTER off)"
	case "$g" in
		off) cfg_set GAME_FILTER tcp ;;
		tcp) cfg_set GAME_FILTER udp ;;
		udp) cfg_set GAME_FILTER all ;;
		*)   cfg_set GAME_FILTER off ;;
	esac
	echo "${D}после смены нужен перезапуск обхода (пункт 3)${N}"
}

run_tests() {
	if [ "$(engine_now)" = macws ]; then
		echo "${D}перебор .bat стратегий на живом движке, нужен пароль администратора${N}"
		printf 'проверять все стратегии, даже если сайты открываются? [y/N] '
		read -r yn
		case "$yn" in [yYдД]*) sudo "$Z" test-bat --force ;; *) sudo "$Z" test-bat ;; esac
	else
		"$Z" test
	fi
}

diagnostics() {
	"$Z" diag
	echo
	"$Z" status
	echo
	debug_on || return 0
	printf 'показать правила pf и проверить параметры (нужен пароль)? [y/N] '
	read -r yn
	case "$yn" in [yYдД]*) sudo "$Z" check ;; esac
}

debug_only() {
	debug_on && return 0
	echo "${Y}это отладочная функция, по умолчанию она выключена${N}"
	echo "${D}включить: DEBUG_TOOLS=1 в macos/config${N}"
	return 1
}

# -------------------------------------------------------------------- цикл --
trap 'echo; exit 0' INT
while :; do
	header
	menu
	printf '\n%s' "выбор: "
	read -r c || exit 0
	echo
	case "$c" in
		1)  sudo "$Z" start "$(strategy_now)"; pause ;;
		2)  sudo "$Z" stop; pause ;;
		3)  sudo "$Z" restart "$(strategy_now)"; pause ;;
		4)  sudo "$Z" install "$(strategy_now)"; pause ;;
		5)  sudo "$Z" uninstall; pause ;;
		6)  choose_strategy; pause ;;
		7)  run_tests; pause ;;
		8)  sudo "$Z" selftest; pause ;;
		9)  toggle_engine; pause ;;
		10) toggle_game_filter; pause ;;
		11) toggle_ipset_filter; pause ;;
		12) "$Z" build; pause ;;
		13) diagnostics; pause ;;
		14) toggle_quic; pause ;;
		15) debug_only && sudo "$Z" debug "$(strategy_now)"; pause ;;
		16) if debug_only; then
		        printf 'какой сайт разобрать? [www.youtube.com] '
		        read -r h
		        sudo "$Z" why "${h:-www.youtube.com}" "$(strategy_now)"
		    fi; pause ;;
		0|q|Q|"") exit 0 ;;
		*)  echo "${R}нет такого пункта${N}"; sleep 1 ;;
	esac
done
