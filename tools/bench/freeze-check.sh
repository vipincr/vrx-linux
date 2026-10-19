#!/bin/sh
# Plan 0012 D2 (G026) on a board: applets behind the screen are frozen.
#
#   tools/bench/freeze-check.sh <board-host>
#
# Opens Home, waits past the 30 s delay, then reads each running applet
# unit's cgroup.freeze: the shell, Home, residents and services run; every
# other hidden applet is frozen. Then opens one frozen applet and checks
# it is thawed and on screen, and that it is frozen again 30 s after
# Home comes back. The harness (ok/bad rows, the Varlink caller, the
# dated record) is bench/lib.sh's, shared with every check (review
# 2026-10-17, KRN-04); this file is the check's body alone.
set -u
HOST=${1:?usage: freeze-check.sh <board-host>}
. "$(dirname "$0")/ssh-env.sh"; O="$OPTS"
. "$(dirname "$0")/lib.sh"

run_check <<'EOF'
push() {
    varlink "io.vrx.Host.Home" >/dev/null
}
push_applet() {
    varlink "io.vrx.Host.Push" "{\"applet\": \"$1\"}" >/dev/null
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
push
sleep 35
victim=""
units=$(systemctl list-units 'vrx-applet@*' --state=active --no-legend --plain | awk '{print $1}')
# CON-08 (review 2026-10-17): no units listed is a failed probe or a
# broken image, never a vacuous pass over zero rows
[ -n "$units" ] || bad "no vrx-applet@ units are active: the probe or the image is wrong"
for u in $units; do
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
    push_applet "$victim"
    sleep 2
    [ "$(freeze_of "$victim")" = 0 ] && ok "$victim thawed when opened" || bad "$victim still frozen when opened"
    journalctl -u vrxhost --since "-5s" --no-pager | grep -q "thawed" && ok "vrxhost logged the thaw" || bad "no thaw logged"
    push
    sleep 35
    [ "$(freeze_of "$victim")" = 1 ] && ok "$victim frozen again 30 s after leaving" || bad "$victim not frozen again"
fi
summary
exit $fails
EOF
finish
