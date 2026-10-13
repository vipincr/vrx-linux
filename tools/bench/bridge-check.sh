#!/bin/sh
# Plan 0008 D15 on a board: the inter-applet bridge across two real
# applets' identities.
#
#   tools/bench/bridge-check.sh <board-host>
#
# vrxhost knows a caller by its cgroup, so the two clients here are put
# into running applets' cgroups (scripts listens, web opens). For the run
# the two manifests in /system/defaults gain a told intent and a channel;
# vrxhost restarts to read them (the UI restarts with it), and both are
# put back, with a second vrxhost restart, at the end.
set -u
HOST=$1
O="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
# shellcheck disable=SC2086
ssh $O "root@$HOST" sh -s <<'EOF'
fails=0
ok()  { echo "  ok    $*"; }
bad() { echo "  FAIL  $*"; fails=$((fails + 1)); }
D=/system/defaults
cp $D/scripts/manifest.toml /tmp/scripts.manifest
cp $D/web/manifest.toml /tmp/web.manifest
restore() {
    cp /tmp/scripts.manifest $D/scripts/manifest.toml
    cp /tmp/web.manifest $D/web/manifest.toml
    systemctl restart vrxhost
}
trap restore EXIT
cat >> $D/scripts/manifest.toml <<'M'

[applet.channels]
offers = ["echo"]
M
# a told handler: no route
python3 - <<'P'
import re
p = "/system/defaults/scripts/manifest.toml"
s = open(p).read()
if "[applet.intents]" in s:
    s = s.replace("handles = [", 'handles = [\n    { name = "vrx.bench.ping", priority = 100 },', 1)
else:
    s += '\n[applet.intents]\nhandles = [{ name = "vrx.bench.ping", priority = 100 }]\n'
open(p, "w").write(s)
P
cat >> $D/web/manifest.toml <<'M'

[applet.channels]
opens = ["scripts.echo"]
M
systemctl restart vrxhost
sleep 8

cat > /tmp/bridge.py <<'P'
# A Varlink client with SCM_RIGHTS, placed in an applet's cgroup.
import array, json, os, socket, sys, time
role = sys.argv[1]
cg = {"listen": "scripts", "open": "web"}[role]
import subprocess
path = subprocess.run(["systemctl", "show", "-p", "ControlGroup", "--value", f"vrx-applet@{cg}.service"],
                      capture_output=True, text=True).stdout.strip()
open(f"/sys/fs/cgroup{path}/cgroup.procs", "w").write(str(os.getpid()))
def conn():
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect("/run/vrx/io.vrx.Host")
    return s
def send(s, method, params, more=False):
    m = {"method": method, "parameters": params}
    if more: m["more"] = True
    s.sendall(json.dumps(m).encode() + b"\0")
buf = b""; fds = []
def recv(s):
    global buf
    while b"\0" not in buf:
        data, anc, _, _ = s.recvmsg(4096, socket.CMSG_SPACE(4 * 4))
        for level, kind, d in anc:
            if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                a = array.array("i"); a.frombytes(d[: len(d) - len(d) % 4]); fds.extend(a)
        if not data: return None
        buf += data
    msg, buf = buf.split(b"\0", 1)
    return json.loads(msg)
if role == "listen":
    s = conn(); send(s, "io.vrx.Host.Listen", {}, more=True)
    while True:
        r = recv(s)
        if r is None: break
        p = r.get("parameters", {})
        if p.get("kind") == "intent" and p.get("id") is not None:
            a = conn(); send(a, "io.vrx.Host.Answer", {"id": p["id"], "verdict": "handled"}); recv(a)
            print("listener: answered", p["name"], flush=True)
        elif p.get("kind") == "channel":
            ch = socket.socket(fileno=fds.pop(0))
            line = ch.recv(4096)
            ch.sendall(line.replace(b"ping", b"pong"))
            print("listener: echoed on", p["from"], p["channel"], flush=True)
else:
    time.sleep(1)
    s = conn(); send(s, "io.vrx.Host.Intent", {"name": "vrx.bench.ping"}); print("intent:", json.dumps(recv(s)), flush=True)
    s = conn(); send(s, "io.vrx.Host.Open", {"to": "scripts", "channel": "echo"}); r = recv(s)
    if "error" in r or not fds:
        print("open:", json.dumps(r), flush=True); sys.exit(1)
    ch = socket.socket(fileno=fds.pop(0))
    ch.sendall(b'{"pipe":"scripts.echo","record":"ping"}\n')
    ch.settimeout(3)
    print("channel:", ch.recv(4096).decode().strip(), flush=True)
    s = conn(); send(s, "io.vrx.Host.Open", {"to": "scripts", "channel": "nope"}); print("undeclared:", json.dumps(recv(s)), flush=True)
P
python3 /tmp/bridge.py listen > /tmp/listen.log 2>&1 &
LP=$!
python3 /tmp/bridge.py open > /tmp/open.log 2>&1
sleep 1
kill $LP 2>/dev/null
cat /tmp/open.log /tmp/listen.log | sed 's/^/        /'
grep -q '"verdict": "handled", "handled_by": "scripts"\|"handled_by": "scripts", "verdict": "handled"' /tmp/open.log \
    && ok "a told handler answered inside the budget: handled by scripts" || bad "told intent not handled"
grep -q 'channel: .*pong' /tmp/open.log && ok "web opened scripts.echo; the stream carried a record both ways" || bad "channel"
grep -q 'undeclared: .*NotDeclared' /tmp/open.log && ok "an undeclared channel is refused by name" || bad "undeclared channel not refused"
echo
[ "$fails" -eq 0 ] && echo "bridge-check: all passed" || { echo "bridge-check: $fails failed"; exit 1; }
EOF
