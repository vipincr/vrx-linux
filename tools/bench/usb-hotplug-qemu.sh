#!/bin/sh
# Plan 0019's qemu rung (Part H): devices hot-added to a running
# vrxboard-qemu through the QEMU monitor, and what vrx makes of each: the
# usb_devices fact, the attached/detached/blocked intents in vrxhost's
# journal, a stick's read-only mount and its offer, a network adapter the
# allow-list blocks.
#
#   tools/bench/usb-hotplug-qemu.sh <monitor-socket> <guest-ssh-port> <stick.img>
#
# The guest is started with a monitor socket, an audio backend and the
# image's own xHCI (QB_OPT_APPEND), for example:
#   runqemu vrxboard-qemu nographic slirp \
#     qemuparams="-monitor unix:$PWD/tmp/qemu-mon,server,nowait -audiodev none,id=snd0"
# runqemu's slirp forwards the guest's ssh to <guest-ssh-port> (2222).
# <stick.img> is a FAT image whose apps/ folder holds one applet image
# (<id>.raw); it is attached read-only. The image must be built with
# VRX_USB_CLASSES = "hid storage audio video serial" and the allowlist
# policy (the qemu machine's defaults, plan 0019). Each row prints ok or
# FAIL; the exit status counts the FAILs.
# ok and bad never fail, so `a && ok || bad` is an if; the guest commands are
# composed here on purpose
# shellcheck disable=SC2015,SC2029
set -u
MON=$1 PORT=$2 IMG=$3
O="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 -p $PORT"
fails=0
ok()  { echo "  ok    $*"; }
bad() { echo "  FAIL  $*"; fails=$((fails + 1)); }
# shellcheck disable=SC2086
on() { ssh $O root@localhost "$@"; }
monitor() { printf '%s\n' "$1" | nc -U -w 1 "$MON" >/dev/null; }
# the facts as the system (root) reads them, one field through python
facts() {
    on "python3 -c '
import json, socket
s = socket.socket(socket.AF_UNIX); s.connect(\"/run/vrx/io.vrx.Host\")
s.sendall(json.dumps({\"method\": \"io.vrx.Host.Facts\"}).encode() + b\"\\0\")
buf = b\"\"
while not buf.endswith(b\"\\0\"):
    buf += s.recv(65536)
d = json.loads(buf.rstrip(b\"\\0\"))[\"parameters\"]
print($1)
'"
}
journal() { on "journalctl -u vrxhost -o cat --since '-${2:-20}s' | grep -c '$1'"; }
settle() { sleep "${1:-3}"; }

echo "start: the image declares a host port and the allow-list runs"
[ "$(facts 'd["usb_policy"]')" = allowlist ] && ok "usb_policy is allowlist" || bad "usb_policy: $(facts 'd["usb_policy"]')"
[ "$(facts 'len(d["usb_ports"])')" -ge 1 ] && ok "a host port is declared" || bad "no host port declared"
before=$(facts 'len(d["usb_devices"])')

echo "hub, then a stick behind nothing"
monitor "device_add usb-hub,id=vrxhub"
settle
[ "$(facts 'sum(x["class"]=="hub" for x in d["usb_devices"])')" -ge 1 ] && ok "the hub is listed as hub" || bad "no hub row"
monitor "drive_add 0 if=none,id=vrxstick,file=$IMG,format=raw,readonly=on"
monitor "device_add usb-storage,id=vrxstorage,drive=vrxstick,removable=on"
settle 5
[ "$(journal 'usb attached')" -ge 2 ] && ok "attached raised for both" || bad "attached not raised twice"
mount=$(facts 'next((m for x in d["usb_devices"] for m in x["mounts"]), "")')
if [ -n "$mount" ]; then
    ok "the stick is mounted at $mount"
    on "ls '$mount' >/dev/null"  # the automount mounts on access
    opts=$(on "awk -v m='$mount' '\$2 == m {o = \$4} END {print o}' /proc/mounts")
    for flag in ro nosuid nodev noexec nosymfollow; do
        case ",$opts," in *",$flag,"*) ok "mounted $flag" ;; *) bad "not $flag: $opts" ;; esac
    done
    group=$(on "stat -c %G '$mount'")
    [ "$group" = vrx-usb-media ] && ok "group vrx-usb-media" || bad "group $group"
    on "touch '$mount/x' 2>/dev/null" && bad "the stick is writable" || ok "the stick refuses a write"
    offers=$(on "ls /var/lib/vrx/offers")
    [ -n "$offers" ] && ok "the apps/ folder made an offer: $offers" || bad "no offer from the stick"
else
    bad "the stick is not mounted"
fi

echo "audio dongle"
monitor "device_add usb-audio,id=vrxaudio,audiodev=snd0"
settle
[ "$(facts 'sum(x["class"]=="audio" and x["authorized"] for x in d["usb_devices"])')" -ge 1 ] && ok "audio allowed" || bad "audio not authorised"
on "aplay -l 2>/dev/null | grep -qi usb" && ok "ALSA lists it" || bad "ALSA does not list it"

echo "network adapter: not on the allow-list"
monitor "netdev_add user,id=vrxun"
monitor "device_add usb-net,id=vrxnet,netdev=vrxun"
settle 4
[ "$(facts 'sum(x["blocked"] for x in d["usb_devices"])')" -ge 1 ] && ok "usb-net is blocked" || bad "usb-net not blocked"
[ "$(journal 'usb blocked')" -ge 1 ] && ok "blocked raised" || bad "blocked not raised"
on "ip -o link | grep -q usb0" && bad "a usb0 link appeared" || ok "no driver bound (no usb0)"

echo "pulls"
for dev in vrxnet vrxaudio vrxstorage vrxhub; do monitor "device_del $dev"; done
settle 4
[ "$(journal 'usb detached' 10)" -ge 4 ] && ok "detached raised for each" || bad "detached not raised for each"
[ "$(facts 'len(d["usb_devices"])')" = "$before" ] && ok "the list is back to $before" || bad "the list did not empty"
[ -z "$(on "grep ' /run/vrx/usb/' /proc/mounts || true")" ] && ok "no mount left behind" || bad "a mount is left"

echo "$fails FAIL"
exit "$fails"
