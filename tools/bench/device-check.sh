#!/bin/sh
# Plan 0008 D16 on a board: devices are grants like the rest. An applet
# unit has DevicePolicy=closed, so a device its grants do not name cannot
# be opened even when its groups would allow it; each grant's device
# classes (grants.conf) open it.
#
#   tools/bench/device-check.sh <board-host>
#
# Read-only: transient units open device nodes and close them.
set -u
HOST=$1
GRANTS=$(dirname "$0")/../../layer/recipes-applets/vrx-applets/files/grants.conf
O="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
# shellcheck disable=SC2086
scp -q $O "$GRANTS" "root@$HOST:/tmp/vrx-grants.conf" || exit 1
# shellcheck disable=SC2086
ssh $O "root@$HOST" sh -s <<'EOF2'
GRANTS_CONF=$(cat /tmp/vrx-grants.conf)
export GRANTS_CONF
fails=0
ok()   { echo "  ok    $*"; }
bad()  { echo "  FAIL  $*"; fails=$((fails + 1)); }
# open NODE as an applet user holding GROUP, under DevicePolicy=closed,
# with the given DeviceAllow (empty: none)
opens() {
    node=$1 group=$2 allow=$3 cmd=$4
    systemd-run --quiet --wait --pipe -p User=vrx-clock -p DevicePolicy=closed \
        -p "SupplementaryGroups=$group" ${allow:+-p "DeviceAllow=$allow rw"} -- sh -c "$cmd" >/dev/null 2>&1
}
class_of() { echo "$GRANTS_CONF" | awk -v g="$1" '$1==g && $2=="=" {print $4}'; }
group_of() { echo "$GRANTS_CONF" | awk -v g="$1" '$1==g && $2=="=" {print $3}'; }

echo "== a device opens only with its grant (DevicePolicy=closed)"
# grant, node, how to open it (stty opens a tty without waiting for carrier)
for row in "serial /dev/ttyS0 stty" "audio /dev/snd/controlC0 cat" "input /dev/input/event0 cat"; do
    set -- $row
    grant=$1 node=$2 how=$3
    [ -e "$node" ] || { echo "  skip  $grant: no $node on this board"; continue; }
    class=$(class_of "$grant") group=$(group_of "$grant")
    case $how in
        stty) cmd="stty -F $node" ;;
        cat) cmd="exec 3< $node" ;;
    esac
    if opens "$node" "$group" "" "$cmd"; then bad "$grant: $node opened without $class"; else ok "$grant: $node refused without $class (group $group held)"; fi
    if opens "$node" "$group" "$class" "$cmd"; then ok "$grant: $node opens with $class"; else bad "$grant: $node refused with $class"; fi
done

echo "== every applet unit allows exactly its grants' devices"
python3 - <<'EOF3' || fails=$((fails + 1))
import glob, os, re, subprocess, sys
grants = {}
for line in os.environ["GRANTS_CONF"].splitlines():
    line = line.split("#")[0].strip()
    if "=" in line:
        key, rest = (p.strip() for p in line.split("=", 1))
        # device classes only: settings' path: is a ReadWritePaths entry
        grants[key] = [t for t in rest.split()[1:] if t.startswith(("char-", "block-"))]
# what every applet unit allows whatever its grants (vrx-applet@.service)
base = None
bad = 0
for manifest in sorted(glob.glob("/system/defaults/*/manifest.toml")):
    text = open(manifest).read()
    applet = re.search(r'^id = "([^"]+)"', text, re.M).group(1)
    m = re.search(r'^system = \[([^\]]*)\]', text, re.M)
    held = re.findall(r'"([^"]+)"', m.group(1)) if m else []
    want = {c for g in held for c in grants.get(g, [])}
    out = subprocess.run(["systemctl", "show", "-p", "DevicePolicy", "-p", "DeviceAllow", "--value", f"vrx-applet@{applet}"],
                         capture_output=True, text=True).stdout.split("\n")
    # one DeviceAllow entry per line: "char-rtc r"
    policy, allow = out[0], " ".join(out[1:]).split()
    have = {allow[i] for i in range(0, len(allow), 2)}
    if policy == "auto":
        print(f"  skip  {applet}: DevicePolicy=auto (the debug terminal)")
        continue
    extra = have - want
    if base is None:
        base = extra
    missing = want - have
    if policy != "closed" or missing or extra != base:
        print(f"  FAIL  {applet}: policy {policy}, missing {sorted(missing)}, beyond the base {sorted(extra - base)}")
        bad += 1
    else:
        print(f"  ok    {applet}: closed, {sorted(want) or 'no device grant'} beyond the base {sorted(base)}")
sys.exit(1 if bad else 0)
EOF3
echo
[ "$fails" -eq 0 ] && echo "device-check: all passed" || { echo "device-check: $fails failed"; exit 1; }
EOF2
