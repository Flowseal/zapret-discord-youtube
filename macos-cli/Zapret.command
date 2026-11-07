#!/bin/sh
set -eu
DIR=$(CDPATH= cd -- "$(/usr/bin/dirname -- "$0")" && pwd -P)
exec "$DIR/zapret"
