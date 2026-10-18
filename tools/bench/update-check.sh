#!/bin/sh
# Plan 0016 on a board with the A/B layout: the slots, RAUC's refusals,
# an install and its trial boot, the fall-back, the Manage upload and
# (written, run only in an owner session) the power-cut rows.
#
#   tools/bench/update-check.sh <board-host> layout
#   tools/bench/update-check.sh <board-host> refuse <unsigned> <other-machine> <older>
#   tools/bench/update-check.sh <board-host> install <bundle>      then restarts
#   tools/bench/update-check.sh <board-host> kept <from-slot>      after the restart
#   tools/bench/update-check.sh <board-host> fallback <bad-bundle> a UI that never starts
#   tools/bench/update-check.sh <board-host> upload <bundle>       through vrx-manage
#   tools/bench/update-check.sh <board-host> power-cut-slot <bundle>
#   tools/bench/update-check.sh <board-host> power-cut-autoboot
#
# Bundles are files on this Mac (vrx-bundle's deploy output, or ones made
# wrong on purpose for the refuse row). They are copied into
# /data/vrx/updates, which is where the USB drive's updates/ folder and
# the Manage upload land too; the calls come from the Settings applet's
# cgroup (it holds the update grant) and one from the launcher's (it does
# not), the identity trick install-check.sh uses. Each phase prints ok or
# FAIL per row and exits non-zero on any FAIL.
set -u
HOST=$1 PHASE=$2
shift 2
. "$(dirname "$0")/ssh-env.sh"; O="$OPTS"
# shellcheck disable=SC2086
on() { ssh $O "root@$HOST" "$@"; }
# shellcheck disable=SC2086
put() { scp -q $O "$1" "root@$HOST:/data/vrx/updates/$(basename "$1")"; }

# the board side: helpers, then the phase's rows
BOARD=$(cat <<'EOF'
fails=0
ok()   { echo "  ok    $*"; }
bad()  { echo "  FAIL  $*"; fails=$((fails + 1)); }
check() { desc=$1; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi; }
cat > /tmp/upd.py <<'P'
# One Varlink call from an applet's identity (its cgroup), printed as JSON.
import json, os, socket, subprocess, sys
who, method = sys.argv[1], sys.argv[2]
params = json.loads(sys.argv[3]) if len(sys.argv) > 3 else {}
if who != "system":
    cg = subprocess.run(["systemctl", "show", "-p", "ControlGroup", "--value", f"vrx-applet@{who}.service"],
                        capture_output=True, text=True).stdout.strip()
    if not cg:
        print(json.dumps({"error": f"{who} is not running"})); sys.exit(0)
    # vrxhost freezes an applet hidden for 30 s, and this call joins its
    # cgroup: an install outlasts that, and a frozen caller never reads the
    # answer. A child started before the move stays in this session's
    # cgroup and keeps thawing the applet until the answer is in.
    keeper = subprocess.Popen(["sh", "-c", f"while :; do systemctl thaw vrx-applet@{who}.service; sleep 5; done"])
    open(f"/sys/fs/cgroup{cg}/cgroup.procs", "w").write(str(os.getpid()))
s = socket.socket(socket.AF_UNIX); s.connect("/run/vrx/io.vrx.Host")
s.sendall(json.dumps({"method": f"io.vrx.Host.{method}", "parameters": params}).encode() + b"\0")
buf = b""
while not buf.endswith(b"\0"):
    d = s.recv(65536)
    if not d: break
    buf += d
if who != "system":
    keeper.kill()
print(buf.rstrip(b"\0").decode())
P
call() { python3 /tmp/upd.py "$@"; }
field() { python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print($1)"; }
# autoboot.txt off the config partition: where the image mounts it (/boot,
# read-write, so a read-only mount of it is refused), else mounted here
autoboot_txt() {
    dev=$(readlink -f /dev/disk/by-partlabel/config)
    dir=$(awk -v d="$dev" '$1 == d {print $2; exit}' /proc/mounts)
    if [ -n "$dir" ]; then cat "$dir/autoboot.txt"; return; fi
    mkdir -p /run/vrx/cfg && mount -o ro "$dev" /run/vrx/cfg && cat /run/vrx/cfg/autoboot.txt
    umount /run/vrx/cfg 2>/dev/null
}
# its boot_partition under [all] or [tryboot]
autoboot() {
    autoboot_txt | awk -v s="[$1]" '/^\[/ {cur=$0} cur==s && /^boot_partition=/ {sub(/.*=/, ""); print}'
}
tryboot_a_b() { autoboot_txt | grep -q '^tryboot_a_b=1'; }
problem_of() { echo "$OFFERS" | field "next((str(o['problem']) for o in d['parameters']['offers'] if o['file']=='$1'), 'absent')"; }
EOF
)

WORST=0
run() {
    # shellcheck disable=SC2029
    if ! on "PHASE='$PHASE' A1='${1:-}' A2='${2:-}' A3='${3:-}' sh -s" <<EOF
$BOARD
$(cat)
exit \$fails
EOF
    then
        # the exit status is the WORST of all runs (review 2026-10-17,
        # CON-08: the last run's status answered for the whole phase)
        WORST=1
    fi
}
trap 'exit $WORST' EXIT

case $PHASE in
layout) run <<'EOF'
echo "== the A/B layout (D3) and RAUC (D1, D5)"
for l in config boot_a boot_b root_a root_b data; do
    check "partition $l"          test -e /dev/disk/by-partlabel/$l
done
check "/data is p6, the last"     grep -q 'p6 /data ' /proc/mounts
check "/data grew past 1 GiB"     sh -c '[ $(df -k /data | awk "NR==2 {print \$2}") -gt 1048576 ]'
check "autoboot.txt: tryboot_a_b=1" tryboot_a_b
echo "        [all] boot_partition=$(autoboot all), [tryboot] boot_partition=$(autoboot tryboot)"
check "rauc is running"           systemctl is-active rauc
check "booted slot A, first boot" sh -c 'rauc status --output-format=json | grep -q "\"booted\":\"A\""'
check "plain bundles refused (G046)" grep -q '^bundle-formats=-plain' /usr/lib/rauc/system.conf
check "a keyring (G046)"          sh -c 'k=$(sed -n "s/^path=//p" /usr/lib/rauc/system.conf | head -n 1); test -s "$k"'
check "update.conf"               test -s /usr/lib/vrx/update.conf
check "the health target exists"  systemctl cat vrx-update-healthy.target
check "only vrx-update-mark marks good (G047)" sh -c '! grep -rl "mark-good" /usr/lib/systemd/system /etc/systemd/system | grep -v vrx-update-mark.service'
# tryboot needs an EEPROM from 2021 or later (D2), and one from 2025-10-08 or
# later to switch every time (vrx-bootloader-check says so at boot)
echo "        bootloader: $(vcgencmd bootloader_version 2>/dev/null | head -n 1)"
check "the bootloader switches reliably (vrx-bootloader-check)" sh -c '! journalctl -b -u vrx-bootloader-check | grep -q predates'
check "the config partition is mounted read-only once" sh -c '[ "$(awk "\$1 ~ /mmcblk0p1\$/" /proc/mounts | wc -l)" = 1 ] && awk "\$2 == \"/boot/config\" && \$4 ~ /^ro,/" /proc/mounts | grep -q .'
check "the shell's first frame reported" test -e /run/vrx/shell-shown
check "this boot was marked good" sh -c 'rauc status --output-format=json | python3 -c "import json,sys; d=json.load(sys.stdin); b=d[\"booted\"]; print([s for x in d[\"slots\"] for n,s in x.items() if s.get(\"bootname\")==b and s[\"class\"]==\"rootfs\"][0][\"boot_status\"])" | grep -q good'
EOF
;;
refuse)
    for b in "$@"; do put "$b"; done
    run "$(basename "$1")" "$(basename "$2")" "$(basename "$3")" <<'EOF'
echo "== refusals (G046, G049, D11)"
OFFERS=$(call settings UpdateOffers)
check "unsigned or plain: refused before mount" sh -c "[ '$(problem_of "$A1")' = unsigned ]"
check "another machine's: refused"   sh -c "[ '$(problem_of "$A2")' = machine ]"
grep -q '^downgrades=yes' /usr/lib/vrx/update.conf && MODE=debug || MODE=release
if [ $MODE = release ]; then
    check "older on release: refused (G049)" sh -c "[ '$(problem_of "$A3")' = older ]"
    R=$(call system UpdateInstall "{\"file\": \"$A3\"}")
    echo "$R" | grep -q UpdateRefused && ok "installing it anyway: UpdateRefused" || bad "older install: $R"
else
    check "older on debug: offered"      sh -c "[ '$(problem_of "$A3")' = None ]"
fi
R=$(call launcher UpdateOffers)
echo "$R" | grep -q NotPermitted && ok "no update grant: NotPermitted" || bad "launcher: $R"
rm -f "/data/vrx/updates/$A1" "/data/vrx/updates/$A2" "/data/vrx/updates/$A3"
EOF
;;
install)
    put "$1"
    run "$(basename "$1")" <<'EOF'
echo "== install into the other slot, restart on trial (D2)"
FROM=$(rauc status --output-format=json | field "d['booted']")
echo "        booted $FROM"
mkdir -p /data/vrx/update
printf '%s\n' "$FROM" > /data/vrx/update/bench-from
OFFERS=$(call settings UpdateOffers)
check "offered, nothing wrong"   sh -c "[ '$(problem_of "$A1")' = None ]"
R=$(call settings UpdateInstall "{\"file\": \"$A1\"}")
echo "$R" | grep -q '"version"' && ok "installed: $R" || bad "install: $R"
check "the bundle is gone from updates/" sh -c "! test -e /data/vrx/updates/$A1"
echo "        [all]=$(autoboot all) [tryboot]=$(autoboot tryboot)"
check "[tryboot] names the other boot partition" sh -c "[ \"$(autoboot tryboot)\" != \"$(autoboot all)\" ]"
if [ "$fails" -eq 0 ]; then
    echo "$FROM" > /data/vrx/update/bench-from
    call settings UpdateRestart >/dev/null &
    ok "restarting with the board's reboot argument; run: update-check.sh <host> kept $FROM"
else
    echo "        not restarting: the install did not go through"
fi
EOF
;;
kept) run "$1" <<'EOF'
echo "== the trial boot reached health and was kept (D6)"
B=$(rauc status --output-format=json | field "d['booted']")
check "booted the other slot ($B, from $A1)" sh -c "[ '$B' != '$A1' ]"
check "the health target was reached" systemctl is-active vrx-update-healthy.target
check "vrx-update-mark succeeded" sh -c 'systemctl show -p Result --value vrx-update-mark.service | grep -q success'
echo "        [all]=$(autoboot all) [tryboot]=$(autoboot tryboot)"
check "[all] now names this slot's boot partition" sh -c "[ \"$(autoboot all)\" = \"$(autoboot tryboot)\" ]"
S=$(call settings UpdateStatus)
# the first reader of a kept outcome consumes vrxhost's record, and the
# Settings applet reads it when it starts: "kept" once, then "none" with
# the record gone and this slot booted
if echo "$S" | grep -q '"last": *"kept"'; then
    ok "Settings says kept"
elif echo "$S" | grep -q '"last": *"none"' && ! test -e /data/vrx/update/pending.json; then
    ok "kept, and the record already read (Settings read it when it started)"
else
    bad "status: $S"
fi
check "the fall-back timer is stopped" sh -c '! systemctl is-active vrx-update-fallback.timer'
EOF
;;
fallback)
    put "$1"
    run "$(basename "$1")" <<'EOF'
echo "== a bundle whose UI never starts (D6): install, then restart"
# bench-from is written HERE, by every phase that moves the slot (review
# 2026-10-17, CON-10: only install and power-cut-slot wrote it, so a
# fall-back judged itself against whatever slot an older phase named)
mkdir -p /data/vrx/update
rauc status --output-format=json | field "d['booted']" > /data/vrx/update/bench-from
R=$(call settings UpdateInstall "{\"file\": \"$A1\"}")
echo "$R" | grep -q '"version"' && ok "installed" || bad "install: $R"
call settings UpdateRestart >/dev/null &
ok "restarting; the trial boot must miss the target and reboot plainly at 180 s"
EOF
    echo "  ..    waiting 300 s for the trial and the fall-back"
    sleep 300 # poll-ok: a bench script waiting out a 180 s timer and two boots
    run <<'EOF'
S=$(call settings UpdateStatus)
echo "$S" | grep -q '"last": *"fell-back"' && ok "Settings says it went back" || bad "status: $S"
# a missing record is a failure, never an empty compare that reads true
[ -s /data/vrx/update/bench-from ] || bad "no bench-from record: nothing to compare the fall-back against"
FROM=$(cat /data/vrx/update/bench-from 2>/dev/null || echo none)
NOW=$(rauc status --output-format=json | field "d['booted']")
[ "$FROM" != none ] && check "booted the slot it came from ($FROM -> $NOW)" sh -c "[ '$NOW' = '$FROM' ]"
EOF
;;
upload)
    run <<'EOF'
systemctl start vrx-manage.service && ok "vrx-manage started" || bad "vrx-manage"
EOF
    NAME=$(basename "$1")
    R=$(curl -s -H 'Expect:' -H 'X-Vrx-Upload: 1' --data-binary @"$1" "http://$HOST/api/update")
    echo "$R" | grep -q '"stored":"manage-upload.raucb"' && echo "  ok    uploaded $NAME: $R" || echo "  FAIL  upload: $R"
    R=$(curl -s --data-binary @"$1" "http://$HOST/api/update")
    echo "$R" | grep -q 'X-Vrx-Upload' && echo "  ok    no header: refused" || echo "  FAIL  headerless: $R"
    run <<'EOF'
OFFERS=$(call settings UpdateOffers)
check "the upload is offered" sh -c "[ '$(problem_of manage-upload.raucb)' = None ]"
systemctl stop vrx-manage.service
EOF
;;
power-cut-slot)
    # owner session only: the owner pulls the supply when told
    put "$1"
    run "$(basename "$1")" <<'EOF'
echo "== power cut while RAUC writes the slot (owner session)"
FROM=$(rauc status --output-format=json | field "d['booted']")
echo "$FROM" > /data/vrx/update/bench-from
call settings UpdateInstall "{\"file\": \"$A1\"}" >/dev/null 2>&1 &
sleep 20 # poll-ok: into the slot write before the signal
echo "  >>    PULL THE SUPPLY NOW, wait 5 s, restore it; then run: update-check.sh <host> power-cut-slot-after"
EOF
;;
power-cut-slot-after) run <<'EOF'
check "booted the slot it came from" sh -c "[ \"$(rauc status --output-format=json | field \"d['booted']\")\" = \"$(cat /data/vrx/update/bench-from)\" ]"
echo "        [all]=$(autoboot all) [tryboot]=$(autoboot tryboot)"
check "[tryboot] does not name a half-written slot" sh -c "[ \"$(autoboot all)\" = \"$(autoboot tryboot)\" ]"
check "/data is intact" test -d /data/vrx
EOF
;;
power-cut-autoboot) run <<'EOF'
echo "== power cut while autoboot.txt is rewritten (owner session)"
# the backend's write is a rename: loop set-primary between the slots
# and cut the supply mid-loop; either file is a valid one
( while :; do /usr/lib/vrx/update/tryboot-backend set-primary rootfs.1; /usr/lib/vrx/update/tryboot-backend set-primary rootfs.0; done ) &
echo "  >>    PULL THE SUPPLY NOW, wait 5 s, restore it; then run: update-check.sh <host> layout"
sleep 30 # poll-ok: keeps the loop running until the cut
EOF
;;
*) echo "update-check: unknown phase $PHASE" >&2; exit 64 ;;
esac
