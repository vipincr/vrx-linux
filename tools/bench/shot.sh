#!/bin/sh
# Tap points on the board's screen, then read the scanout back to a PNG on
# the bench Mac.
#
#   tools/bench/shot.sh <board-host> <out.png> [x y]...
#
# tap.py and scanout.py must be in /root/bench on the board (copied by
# this script when missing). Each tap is 1.2 s apart, so a screen settles
# before the next. The read-back stalls the pipeline: never shoot inside a
# measurement window.
set -eu
HOST=$1; OUT=$2; shift 2
HERE=$(cd "$(dirname "$0")" && pwd)
O="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
# shellcheck disable=SC2086
ssh $O "root@$HOST" 'mkdir -p /root/bench; ls /root/bench/tap.py /root/bench/scanout.py' >/dev/null 2>&1 \
    || scp -q $O "$HERE/tap.py" "$HERE/scanout.py" "$HERE/hid.py" "$HERE/drmprops.py" "root@$HOST:/root/bench/"
TAPS=""
while [ $# -ge 2 ]; do TAPS="$TAPS python3 tap.py $1 $2 >/dev/null 2>&1; sleep 1.2;"; shift 2; done
# shellcheck disable=SC2086
ssh $O "root@$HOST" "cd /root/bench && $TAPS python3 scanout.py /tmp/shot.png >/dev/null"
# shellcheck disable=SC2086
scp -q $O "root@$HOST:/tmp/shot.png" "$OUT" && echo "$OUT"
