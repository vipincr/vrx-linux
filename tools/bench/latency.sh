#!/bin/sh
# The responsiveness bench gate (plan 0008 D18): taps an applet through a
# uinput touchscreen and reads the compositor's input-to-screen trace.
# Exits non-zero when the p95 is over budget.
#
#   tools/bench/latency.sh <board-host> <applet> <x> <y> [taps] [budget-ms]
#
# x, y are panel pixels of something that redraws on tap. Runs over ssh
# as root; turns the profiler's switch on for the run and off after (plan
# 0014 D7: input-to-screen latency is part of the compositor's flip
# record, so the image needs meta-vrx-profiling).
set -eu
HOST=$1 APPLET=$2 X=$3 Y=$4 TAPS=${5:-20} BUDGET=${6:-50}
DIR=$(cd "$(dirname "$0")" && pwd)
SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@$HOST"
scp -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$DIR/tap.py" "root@$HOST:/run/vrx-bench-tap.py"
$SSH "set -e
varlinkctl call /run/vrx/io.vrx.Host io.vrx.Host.Profiling '{\"on\":true}' >/dev/null
varlinkctl call /run/vrx/io.vrx.Host io.vrx.Host.Push '{\"applet\":\"$APPLET\"}' >/dev/null
sleep 2
start=\$(date '+%Y-%m-%d %H:%M:%S')
python3 /run/vrx-bench-tap.py $X $Y $TAPS 0.6
journalctl -u vrx-ui --since \"\$start\" --no-pager | sed -n 's/.*input→screen \([0-9.]*\) ms.*/\1/p' > /run/vrx-bench.ms
varlinkctl call /run/vrx/io.vrx.Host io.vrx.Host.Profiling '{\"on\":false}' >/dev/null
rm -f /run/vrx-bench-tap.py" 
$SSH "sort -n /run/vrx-bench.ms" > /tmp/vrx-bench.$$
n=$(wc -l < /tmp/vrx-bench.$$ | tr -d ' ')
if [ "$n" -eq 0 ]; then
    echo "bench: no latency samples (did the taps hit something that redraws?)" >&2
    rm -f /tmp/vrx-bench.$$; exit 2
fi
idx=$(( (n * 95 + 99) / 100 ))
p50=$(sed -n "$(( (n + 1) / 2 ))p" /tmp/vrx-bench.$$)
p95=$(sed -n "${idx}p" /tmp/vrx-bench.$$)
rm -f /tmp/vrx-bench.$$
echo "bench: $APPLET: $n taps, input→screen p50 ${p50} ms, p95 ${p95} ms (budget ${BUDGET} ms)"
awk -v p="$p95" -v b="$BUDGET" 'BEGIN { exit !(p <= b) }' || { echo "bench: FAILED, p95 over budget" >&2; exit 1; }
