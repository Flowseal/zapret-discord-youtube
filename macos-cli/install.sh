#!/bin/sh
set -eu
[ "$(/usr/bin/uname -s)" = Darwin ] || { echo 'Нужна macOS 14 или новее' >&2; exit 1; }
DIR=$(CDPATH= cd -- "$(/usr/bin/dirname -- "$0")" && pwd -P)
if [ ! -f "$DIR/vendor/catalog.json" ]; then
    /usr/bin/python3 -I "$DIR/strategies.py" "$DIR/.." "$DIR/vendor"
fi
if [ ! -f "$DIR/bin/utunws" ]; then /bin/sh "$DIR/build.sh"; fi
exec /usr/bin/sudo /usr/bin/python3 -I "$DIR/manager.py" install
