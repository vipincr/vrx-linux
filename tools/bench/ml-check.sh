#!/bin/sh
# Plan 0011 D18 on a board: the local model servers, behind the ml grant.
#
#   tools/bench/ml-check.sh <board-host>
#
# The models are opt-in recipes built into the image (meta-vrx,
# VRX_ML_MODELS): a board whose image lists none has no model units at
# all, and the rows that need a model are skipped. Each model recipe
# installs its file's SHA-256 beside it (models/<file>.sha256, from the
# recipe's SRC_URI checksum), so the board proves it carries exactly the
# bytes the recipe pinned.
#
# The CM4 bench has no microphone, so speech goes through ALSA's loopback
# (snd-aloop): a sentence the bench Mac speaks (say, afconvert) is played
# into Loopback,0 while stt records from Loopback,1 as the default
# capture device. The board's own asound.conf is put back at the end.
set -u
HOST=$1
O="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# the spoken question, made on the bench Mac
if command -v say >/dev/null && command -v afconvert >/dev/null; then
    say -o "$TMP/q.aiff" "What is the tallest mountain in the world?"
    afconvert -f WAVE -d LEI16@16000 -c 1 "$TMP/q.aiff" "$TMP/q.wav"
    # shellcheck disable=SC2086
    scp -q $O "$TMP/q.wav" "root@$HOST:/tmp/vrx-ml-q.wav"
fi

# shellcheck disable=SC2086
ssh $O "root@$HOST" sh -s <<'EOF'
fails=0
ok()   { echo "  ok    $*"; }
bad()  { echo "  FAIL  $*"; fails=$((fails + 1)); }
skip() { echo "  skip  $*"; }
M=/usr/share/vrx-ml/models
CHAT=/usr/share/vrx-ml/chat.gguf
SPEECH=/usr/share/vrx-ml/speech.bin

echo "== the models in the image"
found=0
for sum in "$M"/*.sha256; do
    [ -e "$sum" ] || continue
    found=1
    (cd "$M" && sha256sum -c "$(basename "$sum")" >/dev/null 2>&1) \
        && ok "$(basename "$sum" .sha256): present, SHA-256 matches its recipe" \
        || bad "$(basename "$sum" .sha256): SHA-256 does not match its recipe"
done
[ $found = 1 ] || skip "this image lists no model (VRX_ML_MODELS)"
[ ! -d /var/lib/vrx-ml ] && ok "no model store on /data: nothing is downloaded on the device" || bad "/var/lib/vrx-ml exists"

echo "== the units, for the roles this image has"
for role in chat speech; do
    case $role in chat) u=vrx-llm.socket; f=$CHAT; s=llm.sock ;; speech) u=vrx-stt.socket; f=$SPEECH; s=stt.sock ;; esac
    if [ -e "$f" ]; then
        [ "$(systemctl is-active $u)" = active ] && ok "$u listening" || bad "$u is $(systemctl is-active $u)"
        [ "$(stat -c '%A %U %G' /run/vrx-ml/$s)" = "srw-rw---- root vrx-ml" ] \
            && ok "/run/vrx-ml/$s is root:vrx-ml 0660" || bad "$s owner or mode: $(stat -c '%A %U %G' /run/vrx-ml/$s)"
    else
        systemctl cat $u >/dev/null 2>&1 && bad "$u ships without a $role model" || ok "no $role model, no $u"
    fi
done

echo "== G024: the model APIs exist only behind the sockets"
if [ -e $CHAT ]; then
    free | awk 'NR==2 { print "        memory before: " $3 " KiB used, " $7 " KiB available" }'
    T0=$(date +%s)
    R=$(curl -s --max-time 180 --unix-socket /run/vrx-ml/llm.sock http://x/v1/chat/completions \
        -H 'Content-Type: application/json' \
        -d '{"messages":[{"role":"user","content":"What is the tallest mountain in the world? One sentence."}],"max_tokens":64}')
    T1=$(date +%s)
    echo "$R" | grep -q '"content"' && ok "a question through llm.sock answered in $((T1 - T0)) s (cold start included)" || bad "no answer: $R"
    echo "$R" | python3 -c 'import json,sys; t=json.load(sys.stdin).get("timings",{}); print("        prompt %.1f tok/s, generation %.1f tok/s" % (t.get("prompt_per_second",0), t.get("predicted_per_second",0)))' 2>/dev/null
    free | awk 'NR==2 { print "        memory with the model: " $3 " KiB used, " $7 " KiB available" }'
    [ "$(systemctl is-active vrx-llm-server)" = active ] && ok "the socket started llama-server" || bad "llama-server is $(systemctl is-active vrx-llm-server)"
    curl -s --max-time 2 http://127.0.0.1:8081/health >/dev/null && bad "127.0.0.1:8081 answers on the host" || ok "127.0.0.1:8081 is closed on the host while the server runs"
    echo "== an applet without the ml grant cannot reach it"
    systemd-run -q --wait --pipe -p User=vrx-web -p Group=vrx-web \
        curl -s --max-time 5 --unix-socket /run/vrx-ml/llm.sock http://x/health >/dev/null 2>&1 \
        && bad "vrx-web reached llm.sock" || ok "vrx-web (no ml grant) is refused at the socket"
    systemd-run -q --wait --pipe -p User=vrx-assistant -p Group=vrx-assistant -p SupplementaryGroups=vrx-ml \
        curl -s --max-time 30 --unix-socket /run/vrx-ml/llm.sock http://x/health 2>/dev/null | grep -q ok \
        && ok "vrx-assistant (ml grant) reaches it" || bad "vrx-assistant could not reach llm.sock"
    echo "== a server killed mid-answer"
    (curl -s -N --max-time 60 --unix-socket /run/vrx-ml/llm.sock http://x/v1/chat/completions \
        -H 'Content-Type: application/json' \
        -d '{"messages":[{"role":"user","content":"Count from one to two hundred."}],"stream":true,"max_tokens":400}' > /tmp/vrx-ml-cut.txt) &
    C=$!
    sleep 4
    systemctl kill -s KILL vrx-llm-server
    wait $C
    grep -q 'data: ' /tmp/vrx-ml-cut.txt && ! grep -q '\[DONE\]' /tmp/vrx-ml-cut.txt \
        && ok "the stream stopped without [DONE] (the kit says: The answer was cut short.)" || bad "no partial stream"
    R=$(curl -s --max-time 180 --unix-socket /run/vrx-ml/llm.sock http://x/v1/chat/completions \
        -H 'Content-Type: application/json' -d '{"messages":[{"role":"user","content":"Hi"}],"max_tokens":8}')
    echo "$R" | grep -q '"content"' && ok "the next question starts it again" || bad "no restart: $R"
    echo "== idle: the server stops and its memory comes back"
    for i in $(seq 1 150); do [ "$(systemctl is-active vrx-llm-server)" = active ] || break; sleep 1; done
    [ "$(systemctl is-active vrx-llm-server)" != active ] && ok "llama-server stopped ${i} s after the last request" || bad "still running after 150 s idle"
    free | awk 'NR==2 { print "        memory after: " $3 " KiB used, " $7 " KiB available" }'
else
    skip "this image has no chat model"
fi

echo "== speech"
if [ -e $SPEECH ] && [ -e /tmp/vrx-ml-q.wav ]; then
    R=$(curl -s --max-time 120 --unix-socket /run/vrx-ml/stt.sock http://x/inference \
        -F file=@/tmp/vrx-ml-q.wav -F response_format=json)
    echo "        whisper-server heard: $R"
    echo "$R" | grep -qi 'mountain' && ok "whisper-server wrote the question down" || bad "whisper-server: $R"
    curl -s --max-time 2 http://127.0.0.1:8082/ >/dev/null && bad "127.0.0.1:8082 answers on the host" || ok "127.0.0.1:8082 is closed on the host"
    echo "== stt end to end, through ALSA's loopback"
    modprobe snd-aloop && ok "snd-aloop loaded" || bad "no snd-aloop"
    [ -e /etc/asound.conf ] && cp /etc/asound.conf /tmp/vrx-ml-asound.conf
    cat > /etc/asound.conf <<'A'
pcm.!default { type asym playback.pcm "plughw:Loopback,0,0" capture.pcm "plughw:Loopback,1,0" }
A
    grep -q ': capture ' /proc/asound/pcm && ok "a capture device now exists" || bad "no capture device"
    # sys.stt.listen from the assistant's identity (vrxhost knows a caller
    # by its cgroup), then its sys.stt.heard on the same Listen
    cat > /tmp/vrx-ml-stt.py <<'P'
import json, os, socket, subprocess, sys, time
cg = subprocess.run(["systemctl", "show", "-p", "ControlGroup", "--value", "vrx-applet@assistant.service"],
                    capture_output=True, text=True).stdout.strip()
open(f"/sys/fs/cgroup{cg}/cgroup.procs", "w").write(str(os.getpid()))
def call(method, params, more=False):
    s = socket.socket(socket.AF_UNIX); s.connect("/run/vrx/io.vrx.Host")
    m = {"method": method, "parameters": params}
    if more: m["more"] = True
    s.sendall(json.dumps(m).encode() + b"\0"); return s
def read(s):
    buf = b""
    while not buf.endswith(b"\0"):
        d = s.recv(4096)
        if not d: return None
        buf += d
    return json.loads(buf[:-1])
lis = call("io.vrx.Host.Listen", {}, more=True)
time.sleep(0.5)
print("listen sent:", read(call("io.vrx.Host.Intent", {"name": "sys.stt.listen"})), flush=True)
lis.settimeout(60)
while True:
    r = read(lis)
    if r is None: break
    p = r.get("parameters", {})
    if p.get("kind") == "intent" and p.get("name") == "sys.stt.heard":
        if p.get("id") is not None: read(call("io.vrx.Host.Answer", {"id": p["id"], "verdict": "handled"}))
        print("heard:", json.dumps(p.get("payload")), flush=True); break
P
    systemctl start vrx-applet@assistant
    sleep 3
    # the player starts from here, outside the assistant's cgroup: the
    # assistant holds no audio device, and a child of the client would
    # inherit its device policy (bench, 2026-10-14)
    (sleep 1.5; aplay -q -D plughw:Loopback,0,0 /tmp/vrx-ml-q.wav) &
    python3 /tmp/vrx-ml-stt.py 2>&1 | sed 's/^/        /' | tee /tmp/vrx-ml-stt.log
    grep -qi 'heard: .*mountain' /tmp/vrx-ml-stt.log && ok "sys.stt.listen → recorded, detected, transcribed → sys.stt.heard" || bad "stt end to end"
    rm -f /etc/asound.conf
    [ -e /tmp/vrx-ml-asound.conf ] && mv /tmp/vrx-ml-asound.conf /etc/asound.conf
    rmmod snd-aloop 2>/dev/null
    systemctl restart vrx-applet@assistant
else
    skip "this image has no speech model, or no spoken question (say/afconvert on the bench Mac)"
fi

echo
[ "$fails" -eq 0 ] && echo "ml-check: all passed" || { echo "ml-check: $fails failed"; exit 1; }
EOF
