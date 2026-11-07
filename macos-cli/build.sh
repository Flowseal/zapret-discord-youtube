#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p bin
export SDKROOT=$(/usr/bin/xcrun --sdk macosx --show-sdk-path)
/usr/bin/make -C engine mac
/usr/bin/install -m 755 engine/utunws bin/utunws
/usr/bin/codesign --force --sign - bin/utunws
