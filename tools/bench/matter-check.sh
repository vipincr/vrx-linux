#!/bin/sh
# Plan 0015 on a board: the device on a Matter fabric, from the Mac.
#
#   tools/bench/matter-check.sh <board-host> [node-id]
#
# Needs an image with VRX_MATTER = "1". Runs from the bench Mac on the
# 10.10.10.x link. mDNS first: if the Mac cannot see the board's
# _matterc._udp while the window is open, nothing after it can work, and
# the check says so. Then, with chip-tool (CHIP_TOOL, else on PATH; built
# natively from connectedhomeip with scripts/examples/gn_build_example.sh
# examples/chip-tool out/darwin): pair with the manual code, switch the
# screen off and on, set the brightness, read each back from vrxhost's
# facts and the panel's DPMS, command an endpoint that does not exist, and
# unpair.
set -u
HOST=$1
NODE=${2:-4242}
CHIP=${CHIP_TOOL:-$(command -v chip-tool || true)}
O="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
fails=0
ok()  { echo "  ok    $*"; }
bad() { echo "  FAIL  $*"; fails=$((fails + 1)); }

# one Varlink call on the board as root: socket, method, JSON parameters
call() {
    # shellcheck disable=SC2086
    ssh $O "root@$HOST" python3 - "$1" "$2" "$3" <<'P'
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1])
s.sendall(json.dumps({"method": sys.argv[2], "parameters": json.loads(sys.argv[3])}).encode() + b"\0")
buf = b""
while not buf.endswith(b"\0"):
    buf += s.recv(4096)
print(buf.decode().rstrip("\0"))
P
}
matter() { call /run/vrx-matter/io.vrx.Matter "io.vrx.Matter.$1" "${2:-{\}}"; }
facts() { call /run/vrx/io.vrx.Host io.vrx.Host.Facts '{}'; }
field() { python3 -c "import json,sys; print(json.load(sys.stdin)['parameters'].get('$1'))"; }

echo "== vrx-matter on $HOST"
# shellcheck disable=SC2086
if ssh $O "root@$HOST" systemctl is-active -q vrx-matter; then ok "vrx-matter active"; else bad "vrx-matter not active"; exit 1; fi
state=$(matter State)
echo "  state: $state"
[ "$(echo "$state" | field attestation)" = test ] && ok "test attestation (debug image)" || bad "attestation is not test"

echo "== the window and mDNS"
matter OpenWindow '{"minutes": 3}' >/dev/null
code=$(matter Payload | field manual)
[ ${#code} -eq 11 ] && ok "manual code $code" || bad "no manual code ($code)"
seen=$( (dns-sd -B _matterc._udp local. & pid=$!; sleep 6; kill $pid) 2>/dev/null | grep -c _matterc)
if [ "$seen" -gt 0 ]; then ok "_matterc._udp visible from the Mac"; else bad "_matterc._udp not seen: mDNS does not cross the bench link"; exit 1; fi

if [ -z "$CHIP" ]; then
    echo "== no chip-tool: commissioning rows skipped"
    matter CloseWindow >/dev/null
    exit $fails
fi

echo "== commission with chip-tool"
if "$CHIP" pairing code "$NODE" "$code" >/tmp/matter-pair.log 2>&1; then ok "paired as node $NODE"; else bad "pairing failed (/tmp/matter-pair.log)"; exit 1; fi
[ "$(matter State | field commissioned)" = True ] && ok "the board says commissioned" || bad "the board does not say commissioned"

dpms() {
    # shellcheck disable=SC2086
    ssh $O "root@$HOST" 'cat /sys/class/drm/card*-*/dpms 2>/dev/null | grep -c On'
}
echo "== On/Off: the screen"
"$CHIP" onoff off "$NODE" 1 >/dev/null 2>&1 && sleep 2
[ "$(facts | field screen_on)" = False ] && ok "off: vrxhost says the screen is off" || bad "off: the screen is still on"
[ "$(dpms)" = 0 ] && ok "off: no connector at DPMS On" || bad "off: a connector still On"
"$CHIP" onoff on "$NODE" 1 >/dev/null 2>&1 && sleep 2
[ "$(facts | field screen_on)" = True ] && ok "on: the screen is lit" || bad "on: the screen stayed off"

echo "== Level Control: the brightness"
before=$(facts | field brightness)
if [ "$before" = -1 ]; then
    echo "  this screen cannot dim: level rows skipped"
else
    "$CHIP" levelcontrol move-to-level 128 0 0 0 "$NODE" 1 >/dev/null 2>&1 && sleep 2
    after=$(facts | field brightness)
    [ "$after" -ge 48 ] && [ "$after" -le 52 ] && ok "level 128: brightness $after" || bad "level 128: brightness $after"
    "$CHIP" levelcontrol move-to-level 1 0 0 0 "$NODE" 1 >/dev/null 2>&1 && sleep 2
    [ "$(facts | field screen_on)" = True ] && ok "level 1: the floor, never dark" || bad "level 1 darkened the screen"
    "$CHIP" levelcontrol move-to-level "$((before * 253 / 100 + 1))" 0 0 0 "$NODE" 1 >/dev/null 2>&1
fi

echo "== an endpoint nobody exposed"
if "$CHIP" onoff on "$NODE" 9 >/dev/null 2>&1; then bad "endpoint 9 answered"; else ok "endpoint 9 refused"; fi

echo "== unpair"
"$CHIP" pairing unpair "$NODE" >/dev/null 2>&1
sleep 2
[ "$(matter State | field fabrics)" = 0 ] && ok "no fabric left" || bad "a fabric is left"

[ "$fails" -eq 0 ] && echo "matter-check: all passed" || echo "matter-check: $fails failed"
exit "$fails"
