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
offers = ["echo", "frames"]
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
opens = ["scripts.echo", "scripts.frames"]
M
# web may send only what it emits (plan 0011 D9): the bench ping
python3 - <<'P'
p = "/system/defaults/web/manifest.toml"
s = open(p).read()
if "[applet.intents]" in s:
    s = s.replace("[applet.intents]", '[applet.intents]\nemits = ["vrx.bench.ping"]', 1)
else:
    s += '\n[applet.intents]\nemits = ["vrx.bench.ping"]\n'
open(p, "w").write(s)
P
systemctl restart vrxhost
sleep 8
# the clients join these two applets' cgroups, which exist only while
# they run (a fresh boot is in Setup with neither started)
systemctl start vrx-applet@scripts vrx-applet@web
sleep 3

cat > /tmp/bridge.py <<'P'
# A Varlink client with SCM_RIGHTS, placed in an applet's cgroup.
import array, fcntl, json, mmap, os, socket, sys, time
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
        elif p.get("kind") == "channel" and p.get("channel") == "frames":
            # a buffer queue: the offer line arrives with the buffers
            ch = socket.socket(fileno=fds.pop(0))
            got = b""; bufs = []
            while not got.endswith(b"\n"):
                data, anc, _, _ = ch.recvmsg(1, socket.CMSG_SPACE(4 * 16))
                for level, kind, d in anc:
                    a = array.array("i"); a.frombytes(d[: len(d) - len(d) % 4]); bufs.extend(a)
                got += data
            offer = json.loads(got)
            maps = [mmap.mmap(fd, offer["size"]) for fd in bufs]
            stream_bytes = len(got); n = 0; ok = True
            f = ch.makefile("rwb", buffering=0)
            for line in f:
                stream_bytes += len(line)
                r = json.loads(line)
                # the frame is read from the shared buffer, not the stream
                ok = ok and int.from_bytes(maps[r["index"]][:8], "little") == r["sequence"]
                n += 1
                f.write(json.dumps({"index": r["index"]}).encode() + b"\n")
            print(f"queue: {offer['buffers']} buffers of {offer['size']} bytes, {n} frames read from shared memory, contents {'right' if ok else 'WRONG'}, {stream_bytes} bytes on the stream", flush=True)
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
    # the intent contract (plan 0011 D9): only what web emits, no sys. it
    # does not declare, at most 4 KiB
    s = conn(); send(s, "io.vrx.Host.Intent", {"name": "vrx.bench.nope"}); print("intent undeclared:", json.dumps(recv(s)), flush=True)
    s = conn(); send(s, "io.vrx.Host.Intent", {"name": "sys.alarm.ring"}); print("intent sys:", json.dumps(recv(s)), flush=True)
    s = conn(); send(s, "io.vrx.Host.Intent", {"name": "vrx.bench.ping", "payload": {"d": "x" * 5000}}); print("intent big:", json.dumps(recv(s)), flush=True)
    # a deep link to a route that is not there opens the root (D5)
    s = conn(); send(s, "io.vrx.Host.Push", {"applet": "setup", "route": "renamed"}); print("push renamed:", json.dumps(recv(s)), flush=True)
    s = conn(); send(s, "io.vrx.Host.Home", {}); recv(s)
    # a plain file is not a buffer another applet may map
    s = conn(); plain = os.open("/etc/hostname", os.O_RDONLY)
    s.sendmsg([json.dumps({"method": "io.vrx.Host.Open", "parameters": {"to": "scripts", "channel": "echo"}}).encode() + b"\0"],
               [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", [plain]))])
    print("plain fd:", json.dumps(recv(s)), flush=True)
    # a buffer queue: four sealed memfds handed once, then 1000 frames by index
    s = conn(); send(s, "io.vrx.Host.Open", {"to": "scripts", "channel": "frames"}); r = recv(s)
    q = socket.socket(fileno=fds.pop(0))
    size, count = 4096, 4
    bufs = []
    for i in range(count):
        fd = os.memfd_create(f"frame{i}", os.MFD_ALLOW_SEALING)
        os.ftruncate(fd, size)
        fcntl.fcntl(fd, fcntl.F_ADD_SEALS, fcntl.F_SEAL_SHRINK | fcntl.F_SEAL_GROW)
        bufs.append(fd)
    maps = [mmap.mmap(fd, size) for fd in bufs]
    q.sendmsg([json.dumps({"buffers": count, "size": size}).encode() + b"\n"],
              [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", bufs))])
    f = q.makefile("rwb", buffering=0)
    free = list(range(count)); outstanding = 0
    for seq in range(1, 1001):
        if not free:
            free.append(json.loads(f.readline())["index"]); outstanding -= 1
        i = free.pop(0)
        maps[i][:8] = seq.to_bytes(8, "little")
        f.write(json.dumps({"index": i, "bytes": 8, "sequence": seq}).encode() + b"\n")
        outstanding += 1
    while outstanding:
        f.readline(); outstanding -= 1
    q.shutdown(socket.SHUT_WR)
    time.sleep(1)
    print("queue sent: 1000 frames", flush=True)
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
grep -q 'intent undeclared: .*NotDeclared' /tmp/open.log && ok "an intent web does not emit is refused NotDeclared" || bad "undeclared intent not refused"
grep -q 'intent sys: .*NotDeclared' /tmp/open.log && ok "a sys. intent web does not declare is refused" || bad "sys. intent not refused"
grep -q 'intent big: .*PayloadTooLarge' /tmp/open.log && ok "a 5 KiB payload is refused PayloadTooLarge" || bad "big payload not refused"
grep -q 'push renamed: .*"top": "setup"' /tmp/open.log && ok "a push to an undeclared route opens the root" || bad "renamed route"
grep -q 'plain fd: .*NotShareable' /tmp/open.log && ok "a plain file passed as a buffer is refused NotShareable" || bad "plain fd not refused"
grep -q 'queue: 4 buffers of 4096 bytes, 1000 frames read from shared memory, contents right' /tmp/listen.log \
    && ok "a buffer queue: 4 buffers handed once, 1000 frames read from shared memory, indices only on the stream" || bad "buffer queue"
echo
[ "$fails" -eq 0 ] && echo "bridge-check: all passed" || { echo "bridge-check: $fails failed"; exit 1; }
EOF
