#!/bin/sh
# Plan 0012 D2 (G026) on a board: applets behind the screen are frozen.
#
#   tools/bench/freeze-check.sh <board-host>
#
# Opens Home, waits past the 30 s delay, then reads each running applet
# unit's cgroup.freeze: the shell, Home, residents and services run; every
# other hidden applet is frozen. Then opens one frozen applet and checks
# it is thawed and on screen, and that it is frozen again 30 s after
# Home comes back.
set -u
HOST=$1
O="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
# shellcheck disable=SC2086
ssh $O "root@$HOST" sh -s <<'EOF'
fails=0
ok()  { echo "  ok    $*"; }
bad() { echo "  FAIL  $*"; fails=$((fails + 1)); }
push() {
    python3 - "$1" <<'P'
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.connect("/run/vrx/io.vrx.Host")
method = "io.vrx.Host.Home" if sys.argv[1] == "-" else "io.vrx.Host.Push"
params = {} if sys.argv[1] == "-" else {"applet": sys.argv[1]}
s.sendall(json.dumps({"method": method, "parameters": params}).encode() + b"\0")
print(s.recv(4096).decode().rstrip("\0"))
P
}
freeze_of() {
    cg=$(systemctl show -p ControlGroup --value "vrx-applet@$1.service")
    [ -n "$cg" ] && cat "/sys/fs/cgroup$cg/cgroup.freeze" 2>/dev/null || echo "-"
}
exempt() {
    m=/system/defaults/$1/manifest.toml
    grep -qE '^(home|shell|resident) = true|^kind = "service"|^background = ' "$m" 2>/dev/null
}
echo "== Home, then 35 s"
push - >/dev/null
sleep 35
victim=""
for u in $(systemctl list-units 'vrx-applet@*' --state=active --no-legend --plain | awk '{print $1}'); do
    a=${u#vrx-applet@}; a=${a%.service}
    f=$(freeze_of "$a")
    if exempt "$a"; then
        [ "$f" = 0 ] && ok "$a runs (exempt)" || bad "$a is frozen but exempt"
    else
        [ "$f" = 1 ] && ok "$a is frozen behind the screen" || bad "$a runs behind the screen (cgroup.freeze $f)"
        [ -z "$victim" ] && [ "$f" = 1 ] && victim=$a
    fi
done
if [ -n "$victim" ]; then
    echo "== open $victim"
    push "$victim" >/dev/null
    sleep 2
    [ "$(freeze_of "$victim")" = 0 ] && ok "$victim thawed when opened" || bad "$victim still frozen when opened"
    journalctl -u vrxhost --since "-5s" --no-pager | grep -q "thawed" && ok "vrxhost logged the thaw" || bad "no thaw logged"
    push - >/dev/null
    sleep 35
    [ "$(freeze_of "$victim")" = 1 ] && ok "$victim frozen again 30 s after leaving" || bad "$victim not frozen again"
fi
echo
[ "$fails" -eq 0 ] && echo "freeze-check: all passed" || { echo "freeze-check: $fails failed"; exit 1; }
EOF
