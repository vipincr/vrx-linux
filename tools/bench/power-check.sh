#!/bin/sh
# Plan 0020 D7: the one way a power profile line gets its numbers. One long
# FNB58 session (power-meter.py; restarting sessions froze the meter on
# 2026-10-14), each state held 30 s and read as a time window of the log,
# printed in the profile's own line format so a measurement is pasted,
# never retyped.
#
#   tools/bench/power-check.sh <board-host> [cm4|cm5]
#
# States, in order: screen on, screen off (the floor every saving is
# against), then on a CM4 s2idle (entered over ssh, woken by a Wake-on-LAN
# magic packet from this Mac; skipped where eth0 cannot wake on one, which
# is every CM4 on BCM2711's own device tree), on a CM5
# deep sleep (a power-off with the RTC armed 60 s ahead, timed until the
# current rises again), and last the power-off floor (systemctl poweroff;
# the operator power-cycles the board afterwards). The power-off line says
# standby or halt from the board's own bootloader config (vcgencmd).
#
# Needs: the meter on the Mac's USB with hidapi in $VRX_METER_PYTHON
# (default python3), tap.py in /root/bench on the board (shot.sh copies it),
# and the bench network (scripts/board/bench-network.sh in vrx). The log
# and the results land in this repo's tmp/ (crash-safe).
set -u
HOST=${1:?usage: power-check.sh <board-host> [cm4|cm5]}
BOARD=${2:-cm4}
PY=${VRX_METER_PYTHON:-python3}
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
STAMP=$(date +%Y%m%d-%H%M%S)
DAY=$(date +%Y-%m-%d)
mkdir -p "$REPO/tmp"
CSV="$REPO/tmp/power-check-$STAMP.csv"
OUT="$REPO/tmp/power-check-$STAMP.txt"
. "$(dirname "$0")/ssh-env.sh"; O="$OPTS"
HOLD=30

board() {
    # the command is built here on purpose (paths and values from this script)
    # shellcheck disable=SC2086,SC2029
    ssh $O "root@$HOST" "$@"
}
up() { ping -c1 -t1 "$HOST" >/dev/null 2>&1; }
say() { echo "$*" | tee -a "$OUT"; }

# wait (up to $1 s) until the board answers, or (with "down") stops answering;
# prints the seconds it took, or nothing on a timeout
wait_for() {
    limit=$1 want=${2:-up} t=0
    while [ "$t" -lt "$limit" ]; do
        if up; then [ "$want" = up ] && { echo "$t"; return 0; }
        else [ "$want" = down ] && { echo "$t"; return 0; }; fi
        sleep 1
        t=$((t + 1))
    done
    return 1
}

# hold a state for $HOLD s; records "label start end" for the windows
WINDOWS=""
hold() {
    a=$(date +%s)
    sleep "$HOLD"
    b=$(date +%s)
    WINDOWS="$WINDOWS$1 $a $b
"
}

# mean milliwatts in a window of the log
mw() {
    "$PY" "$HERE/power-meter.py" window "$CSV" "$1" "$2" |
        awk '/ W / { printf "%d", $1 * 1000 }'
}

up || { echo "power-check: $HOST does not answer" >&2; exit 1; }
board 'ls /root/bench/tap.py' >/dev/null 2>&1 || {
    echo "power-check: no /root/bench/tap.py on the board (tools/bench/shot.sh copies it)" >&2
    exit 1
}
MAC=$(board 'cat /sys/class/net/eth0/address')
BOOT=$(board 'vcgencmd bootloader_config 2>/dev/null' || true)
OFF=halt
case "$BOOT" in *POWER_OFF_ON_HALT=1*) OFF=standby ;; esac
say "power-check on $HOST ($BOARD), $DAY; meter log $CSV"
say "bootloader: POWER_OFF_ON_HALT=$(echo "$BOOT" | sed -n 's/^POWER_OFF_ON_HALT=//p') WAKE_ON_GPIO=$(echo "$BOOT" | sed -n 's/^WAKE_ON_GPIO=//p'), so Power off is a $OFF"

# one session for the whole run: long enough for every state and the
# operator's power cycle; stopped when the run ends
"$PY" "$HERE/power-meter.py" log 1800 "$CSV" 2>>"$OUT" &
METER=$!
trap 'kill $METER 2>/dev/null' EXIT INT TERM
sleep 5

# the screen's idle timeout drives on and off; the board's own file is
# restored before the power-off
CONF=/etc/vrx/display/screen.conf
board "cp $CONF /root/bench/screen.conf.before 2>/dev/null; touch $CONF"
light_off() {
    board "grep -v '^light_off=' $CONF > $CONF.new; echo light_off=$1 >> $CONF.new; mv $CONF.new $CONF"
}

light_off 0
board 'cd /root/bench && python3 tap.py 240 320 >/dev/null 2>&1'
sleep 5
say "screen on: holding ${HOLD} s"
hold screen-on

light_off 5
sleep 15
say "screen off: holding ${HOLD} s"
hold screen-off

# a board whose link cannot wake it would sit in s2idle until a power cycle:
# BCM2711's device tree gives bcmgenet no Wake-on-LAN interrupt, so a CM4
# reports "Supports Wake-on: d" and nothing else wakes it (2026-10-15)
WOL=$(board "ethtool eth0 | sed -n 's/^[[:space:]]*Supports Wake-on: //p'")
if [ "$BOARD" = cm4 ] && ! printf '%s' "$WOL" | grep -q g; then
    say "s2idle: skipped: eth0 supports no magic-packet wake (Supports Wake-on: ${WOL:-?}), and nothing else wakes this board"
elif [ "$BOARD" = cm4 ]; then
    say "s2idle: Wake-on-LAN armed, suspending"
    board 'ethtool -s eth0 wol g' || say "s2idle: ethtool refused wol g"
    # detached: the ssh session cannot outlive a suspend cleanly
    # shellcheck disable=SC2086
    ssh -f $O "root@$HOST" 'sleep 2; echo freeze > /sys/power/state' >/dev/null 2>&1
    if wait_for 20 down >/dev/null; then
        sleep 5
        hold s2idle
        "$PY" - "$MAC" <<'P'
import socket, sys
mac = bytes.fromhex(sys.argv[1].replace(":", ""))
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
for _ in range(3):
    s.sendto(b"\xff" * 6 + mac * 16, ("10.10.10.255", 9))
P
        if back=$(wait_for 60); then
            say "s2idle: woke on the magic packet in ${back} s"
        else
            say "s2idle: did not wake on the magic packet in 60 s (power-cycle the board, then rerun from here)"
            S2IDLE_STUCK=1
        fi
    else
        say "s2idle: the board kept answering; it did not suspend (journal: 'PM: suspend entry')"
    fi
fi

if [ "$BOARD" = cm5 ]; then
    light_off 0
    board "cp /root/bench/screen.conf.before $CONF 2>/dev/null || true"
    say "deep sleep: RTC armed 60 s ahead, powering off"
    board 'echo 0 > /sys/class/rtc/rtc0/wakealarm; echo +60 > /sys/class/rtc/rtc0/wakealarm; systemctl poweroff' >/dev/null 2>&1
    gone=$(date +%s)
    sleep 15
    hold deep
    if back=$(wait_for 180); then
        say "deep sleep: answering again $(( $(date +%s) - gone )) s after the power-off (alarm at 60 s; the rest is the boot)"
    else
        say "deep sleep: no answer 240 s after the power-off: the alarm did not wake it"
    fi
fi

if [ -z "${S2IDLE_STUCK:-}" ]; then
    board "cp /root/bench/screen.conf.before $CONF 2>/dev/null || true"
    say "power off ($OFF): powering off; power-cycle the board when this says so"
    board 'systemctl poweroff' >/dev/null 2>&1
    sleep 20
    hold off
    say "power off: measured; power-cycle the board now"
fi

kill "$METER" 2>/dev/null
wait "$METER" 2>/dev/null
trap - EXIT INT TERM

floor=""
say ""
say "# measured $DAY on the FNB58 (tools/bench/power-check.sh); paste into the profile"
echo "$WINDOWS" | while read -r label a b; do
    [ -n "$label" ] || continue
    m=$(mw "$a" "$b")
    [ -n "$m" ] || { say "# $label: no samples"; continue; }
    case "$label" in
        screen-off) floor=$m; say "# screen off (the floor): $m mW" ;;
        screen-on) say "# screen on: $m mW" ;;
        *)
            pct=$(awk -v f="$floor" -v m="$m" 'BEGIN { if (f > 0) printf "%.1f", (f - m) * 100 / f; else print "?" }')
            case "$label" in
                s2idle) say "sleep s2idle saving=$pct% measured=$DAY meter=fnb58  # $m mW" ;;
                deep) say "deep halt saving=$pct% measured=$DAY meter=fnb58  # $m mW" ;;
                off) say "off $OFF saving=$pct% measured=$DAY meter=fnb58  # $m mW" ;;
            esac
            ;;
    esac
done
echo "results: $OUT"
