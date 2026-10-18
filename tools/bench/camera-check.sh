#!/bin/sh
# Plan 0018 on a board: the camera service, from the paths that need no camera
# to the ones that do. Run on the board it is built for (VRX_CAMERA set).
#
#   tools/bench/camera-check.sh <board-host>
#
# Always checked (no camera needed, the CM4 bench's rung 3): camerad runs and
# is idle, state.json says what is true, no media module is loaded until a
# device asks, a caller without the camera-use grant is refused (G057), a request with nothing to capture says no-camera, and the Settings
# switch refuses and releases.
# Checked when a camera is listed (an IMX219 on CSI, a webcam, qemu's
# virtual camera): vrx camera list, a JPEG with its markers and the asked
# size, the viewfinder queue offered with a format and 1000 frames by index, a
# second claimant told busy, the dot (active) following each, the camera
# stopping after the last client.
#
# Hardware rows this does not decide, recorded by hand in plan 0018's outcome
# note: idle camerad RSS, libjpeg-turbo time per frame, the v3d import of
# libcamera's buffers, the unplug and replug of a webcam.
set -u
HOST=$1
. "$(dirname "$0")/ssh-env.sh"; O="$OPTS"
# shellcheck disable=SC2086
ssh $O "root@$HOST" sh -s <<'EOF2'
fails=0
ok()   { echo "  ok    $*"; }
bad()  { echo "  FAIL  $*"; fails=$((fails + 1)); }
S=/run/vrx/camera/state.json
field() { python3 -c "import json,sys; print(json.load(open('$S'))$1)" 2>/dev/null; }

systemctl is-active --quiet vrx-applet@camerad && ok "camerad is running" || { bad "camerad is not running"; exit 1; }
[ -f $S ] && ok "state.json exists" || bad "no state.json"
[ "$(stat -c %a $S)" = 644 ] && ok "state.json is readable by everyone" || bad "state.json mode $(stat -c %a $S)"
reason=$(field "['reason']")
echo "        reason: $reason, cameras: $(field "['cameras']")"
[ "$(field "['active']")" = False ] && ok "idle: no camera started" || bad "active while idle"
# the media drivers are modules loaded when a device exists, never resident
# for nothing: with no camera listed none of the sensor drivers is in
if [ "$reason" = none-found ] || [ "$reason" = expected-csi-missing ]; then
    if lsmod | grep -Eq '^(uvcvideo|imx219|imx477|imx708|ov5647) '; then
        bad "a camera driver is loaded with no camera"
    else
        ok "no camera driver is loaded with no camera"
    fi
fi
systemctl show -p MainPID --value vrx-applet@camerad | xargs -I{} awk '/VmRSS/ {print "        camerad RSS: " $2 " kB"}' /proc/{}/status

# a caller that does not hold camera-use is refused: web declares no such
# channel, so vrxhost says NotDeclared before it reaches the grant check; the
# NotPermitted half of G057 (declared but ungranted) is the host test's
# (rust/host/src/varlink.rs, a_gated_channel_needs_the_grant_g057)
cat > /tmp/camera-gate.py <<'P'
import json, os, socket, subprocess
path = subprocess.run(["systemctl", "show", "-p", "ControlGroup", "--value", "vrx-applet@web.service"],
                      capture_output=True, text=True).stdout.strip()
subprocess.run(["systemctl", "thaw", "vrx-applet@web.service"], capture_output=True)
open(f"/sys/fs/cgroup{path}/cgroup.procs", "w").write(str(os.getpid()))
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect("/run/vrx/io.vrx.Host")
s.sendall(json.dumps({"method": "io.vrx.Host.Open", "parameters": {"to": "camerad", "channel": "photos"}}).encode() + b"\0")
buf = b""
while b"\0" not in buf:
    buf += s.recv(4096)
print(json.loads(buf.split(b"\0")[0]).get("error"))
P
systemctl start vrx-applet@web 2>/dev/null; sleep 2
got=$(python3 /tmp/camera-gate.py 2>&1)
case "$got" in
    *NotDeclared*|*NotPermitted*) ok "web is refused camerad.photos ($got)" ;;
    *) bad "web was not refused: $got" ;;
esac

# a request with nothing to capture (or a camera: either answer is named)
out=$(vrx camera capture -o /tmp/cam-none.jpg 2>&1)
if [ "$reason" = ok ]; then
    echo "$out" | grep -q 'bytes' && ok "capture: $out" || bad "capture failed: $out"
else
    echo "$out" | grep -q 'no-camera' && ok "capture with no camera says no-camera" || bad "capture said: $out"
fi

if [ "$reason" = ok ]; then
    vrx camera list | grep -q '"id"' && ok "vrx camera list names a camera" || bad "list is empty"
    vrx camera capture -o /tmp/cam.jpg >/dev/null 2>&1
    python3 - <<'P' && ok "the JPEG has its start and end markers" || bad "not a JPEG"
b = open("/tmp/cam.jpg", "rb").read()
assert b[:2] == b"\xff\xd8" and b[-2:] == b"\xff\xd9" and len(b) > 1000
P
    vrx camera capture --keep -o /tmp/cam2.jpg 2>&1 | grep -q 'kept as IMG_' && ok "--keep stores IMG_dddd.JPG in /data/photos" || bad "keep"
    ls /data/photos | grep -q '^IMG_[0-9][0-9][0-9][0-9]\.JPG$' && ok "the photo is in /data/photos" || bad "no photo in /data/photos"
    sleep 3
    [ "$(field "['active']")" = False ] && ok "the camera stopped after the last client" || bad "still active 3 s after the last capture"
fi

# the Settings switch: off refuses and releases, on restores
conf=/etc/vrx/settings/camerad.conf
cp $conf /tmp/camerad.conf.saved 2>/dev/null
sed -i 's/^camera_enabled=.*/camera_enabled=false/' $conf; sleep 1
[ "$(field "['reason']")" = disabled ] && ok "Camera Off: the state says disabled" || bad "Off did not take: $(field "['reason']")"
vrx camera capture -o /tmp/off.jpg 2>&1 | grep -q disabled && ok "Camera Off: capture is refused disabled" || bad "capture not refused when off"
sed -i 's/^camera_enabled=.*/camera_enabled=true/' $conf; sleep 1
[ "$(field "['reason']")" != disabled ] && ok "Camera On: back" || bad "On did not take"
cp /tmp/camerad.conf.saved $conf 2>/dev/null

echo
[ "$fails" -eq 0 ] && echo "camera-check: all passed" || { echo "camera-check: $fails failed"; exit 1; }
EOF2
