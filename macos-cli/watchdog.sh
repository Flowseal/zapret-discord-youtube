#!/bin/sh
# A separate process clears interception even if the supervisor is SIGKILLed.
set -eu
SUPERVISOR=$1
ENGINE=$2
while kill -0 "$SUPERVISOR" 2>/dev/null && kill -0 "$ENGINE" 2>/dev/null; do
    /bin/sleep 0.2
done
DIR=$(CDPATH= cd -- "$(/usr/bin/dirname -- "$0")" && pwd -P)
exec /usr/bin/python3 -I "$DIR/manager.py" watchdog-cleanup "$ENGINE"
