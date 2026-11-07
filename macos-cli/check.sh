#!/bin/sh
set -eu
cd "$(dirname "$0")"
if [ ! -f vendor/catalog.json ]; then /usr/bin/python3 -I strategies.py .. vendor; fi
/bin/sh build.sh
/usr/bin/python3 -m unittest discover -s tests -v
CHECK_DIR=$(/usr/bin/mktemp -d /tmp/zapret-native-check.XXXXXX)
cc -std=gnu99 -Wno-address-of-packed-member -Iengine tests/macsend-harness.c engine/checksum.c -o "$CHECK_DIR/macsend"
"$CHECK_DIR/macsend"
cc -g -O1 -fsanitize=address,undefined -ffunction-sections -fdata-sections -Wl,-dead_strip tests/pools-analyzer-harness.c -o "$CHECK_DIR/pools"
"$CHECK_DIR/pools"
cc -g -O1 -fsanitize=address,undefined -ffunction-sections -fdata-sections -Wl,-dead_strip tests/conntrack-analyzer-harness.c engine/packet_queue.c -o "$CHECK_DIR/conntrack"
"$CHECK_DIR/conntrack"
cc -std=gnu99 -O0 -g -Wno-address-of-packed-member -ftrivial-auto-var-init=pattern -fsanitize=address,undefined -Iengine tests/udp-fwmark-harness.c engine/checksum.c engine/conntrack.c engine/darkmagic.c engine/gzip.c engine/helpers.c engine/hostlist.c engine/ipset.c engine/macos_utun.c engine/macsend.c engine/packet_queue.c engine/params.c engine/pools.c engine/protocol.c engine/sec.c engine/crypto/*.c -lz -o "$CHECK_DIR/udp-fwmark"
"$CHECK_DIR/udp-fwmark"
cc -std=gnu99 -g -O1 -fsanitize=address,undefined -ffunction-sections -fdata-sections -Wl,-dead_strip tests/protocol-redirect-harness.c engine/protocol.c engine/helpers.c -o "$CHECK_DIR/protocol"
"$CHECK_DIR/protocol"
echo "Native test binaries: $CHECK_DIR"
