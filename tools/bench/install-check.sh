#!/bin/sh
# Plan 0011 D16, D17, G023 on a board: an applet a person installs is a
# systemd system extension, merged by systemd-sysext, run as a dynamic
# user with no grants, and removed without a trace.
#
#   tools/bench/install-check.sh <board-host>
#
# No new Flutter build: the image reuses a built-in's AOT bundle from the
# board (docs, which needs no grant) under a new id, `hello`, packed by
# `vrx pack` in a Linux container (erofs-utils). Two more images are made
# by hand, because `vrx pack` refuses them itself: one with usr/bin/su
# beside its folder, one whose manifest asks for the network grant.
# vrxhost must refuse both. The calls come from the launcher's cgroup
# (it holds the apps grant) and, for the refusal row, from web's (it does
# not), the identity trick bridge-check.sh uses. The board is left as it
# was: offers, extension, drop-in and state all removed.
set -u
HOST=$1
REPO=$(cd "$(dirname "$0")/../.." && pwd)
O="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "== making the images"
mkdir -p "$WORK/src/hello" "$WORK/out"
# shellcheck disable=SC2086
VER=$(ssh $O "root@$HOST" 'ls /system/defaults/docs | grep -v manifest')
# shellcheck disable=SC2086
ssh $O "root@$HOST" "tar cf - -C /system/defaults/docs $VER" | tar xf - -C "$WORK/src/hello"
cat > "$WORK/src/hello/manifest.toml" <<'M'
# install-check's applet: the docs bundle under another id, no grants
[applet]
id = "hello"
name = "Hello"
version = "1.0.0"
runtime = "flutter"

[applet.display]
icon = "waving_hand"
tile = true
position = 900
M
docker run --rm -v "$REPO:/src:ro" -v vrx-cargo-target:/target -v "$WORK:/work" \
    -e CARGO_TARGET_DIR=/target -w /src rust:1.96.0 sh -ec '
    apt-get -qq update >/dev/null && apt-get -qq install -y erofs-utils >/dev/null
    cargo build -q --locked --release -p vrx-cli
    /target/release/vrx pack /work/src/hello --out /work/out | grep -v "^Processing"
    # by hand: vrx pack refuses these, vrxhost must too
    rel() { mkdir -p "$1/usr/lib/extension-release.d"; printf "ID=vrx\nSYSEXT_LEVEL=1\n" > "$1/usr/lib/extension-release.d/extension-release.$2"; }
    s=/tmp/badsu; mkdir -p $s/usr/lib/vrx/apps/badsu $s/usr/bin
    sed "s/\"hello\"/\"badsu\"/" /work/src/hello/manifest.toml > $s/usr/lib/vrx/apps/badsu/manifest.toml
    printf "#!/bin/sh\n" > $s/usr/bin/su; rel $s badsu
    mkfs.erofs --all-root /work/out/badsu.raw $s >/dev/null
    s=/tmp/badnet; mkdir -p $s/usr/lib/vrx/apps/badnet
    sed "s/\"hello\"/\"badnet\"/" /work/src/hello/manifest.toml > $s/usr/lib/vrx/apps/badnet/manifest.toml
    printf "\n[applet.permissions]\nsystem = [\"network\"]\n" >> $s/usr/lib/vrx/apps/badnet/manifest.toml
    rel $s badnet
    mkfs.erofs --all-root /work/out/badnet.raw $s >/dev/null
    ls -l /work/out' || { echo "install-check: could not make the images"; exit 1; }
# shellcheck disable=SC2086
scp -q $O "$WORK/out/hello.raw" "$WORK/out/badsu.raw" "$WORK/out/badnet.raw" "root@$HOST:/tmp/" || exit 1

# shellcheck disable=SC2086
ssh $O "root@$HOST" sh -s <<'EOF'
fails=0
ok()  { echo "  ok    $*"; }
bad() { echo "  FAIL  $*"; fails=$((fails + 1)); }
OFFERS=/var/lib/vrx/offers
# idempotent: a run cut short (the bench loses power) leaves its applets
# behind; clear them before starting
clean() {
    left=no
    for a in hello badsu badnet; do
        for p in /var/lib/extensions/$a.raw /etc/systemd/system/vrx-applet@$a.service.d \
                 /etc/vrx/settings/$a.conf /var/lib/private/vrx/$a /var/cache/private/vrx/$a $OFFERS/$a.raw; do
            [ -e "$p" ] && { rm -rf "$p"; left=yes; }
        done
    done
    systemd-sysext status --no-pager 2>&1 | grep -qE 'hello|badsu|badnet' && left=yes
    if [ $left = yes ]; then
        systemctl stop vrx-applet@hello 2>/dev/null
        systemd-sysext refresh >/dev/null 2>&1
        systemctl daemon-reload
        systemctl restart vrxhost
        sleep 8
        echo "        cleared what an earlier run left"
    fi
}
clean
had_offers=no; [ -d $OFFERS ] && had_offers=yes
mkdir -p $OFFERS
cp /tmp/hello.raw /tmp/badsu.raw /tmp/badnet.raw $OFFERS/
systemctl start vrx-applet@web
sleep 2

cat > /tmp/inst.py <<'P'
# One Varlink call from an applet's identity (its cgroup), printed as JSON.
import json, os, socket, subprocess, sys
who, method = sys.argv[1], sys.argv[2]
params = json.loads(sys.argv[3]) if len(sys.argv) > 3 else {}
cg = subprocess.run(["systemctl", "show", "-p", "ControlGroup", "--value", f"vrx-applet@{who}.service"],
                    capture_output=True, text=True).stdout.strip()
if not cg:
    print(json.dumps({"error": f"{who} is not running"})); sys.exit(0)
open(f"/sys/fs/cgroup{cg}/cgroup.procs", "w").write(str(os.getpid()))
s = socket.socket(socket.AF_UNIX); s.connect("/run/vrx/io.vrx.Host")
s.sendall(json.dumps({"method": f"io.vrx.Host.{method}", "parameters": params}).encode() + b"\0")
buf = b""
while not buf.endswith(b"\0"):
    d = s.recv(65536)
    if not d: break
    buf += d
print(buf.rstrip(b"\0").decode())
P
call() { python3 /tmp/inst.py "$@"; }
field() { python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print($1)"; }

echo "== offers"
OFFERS_JSON=$(call launcher Offers)
offer() { echo "$OFFERS_JSON" | field "next((json.dumps(o) for o in d['parameters']['offers'] if o['id']=='$1'), '')"; }
H=$(offer hello)
echo "        hello: $H"
echo "$H" | grep -q '"kind": "install"' && echo "$H" | grep -q '"problem": null' \
    && ok "hello is offered for install, nothing wrong with it" || bad "hello offer"
BUILD=$(echo "$H" | field "d['build']")
[ "$BUILD" = "$(sha256sum $OFFERS/hello.raw | cut -d' ' -f1)" ] \
    && ok "the build is the image's SHA-256" || bad "build is not the image's sha256"
offer badsu | grep -q '"problem": "paths"' && ok "badsu (usr/bin/su beside its folder) offered with problem paths" || bad "badsu offer: $(offer badsu)"
offer badnet | grep -q '"problem": "manifest"' && ok "badnet (asks for the network grant) offered with problem manifest" || bad "badnet offer: $(offer badnet)"

echo "== refusals (G023)"
R=$(call web Install "{\"file\": \"hello.raw\", \"build\": \"$BUILD\"}")
echo "$R" | grep -q 'NotPermitted' && ok "web (no apps grant) may not install: NotPermitted" || bad "web install: $R"
R=$(call launcher Install "{\"file\": \"badsu.raw\", \"build\": \"x\"}")
echo "$R" | grep -q 'OfferRefused' && echo "$R" | grep -q '"paths"' && ok "an image with usr/bin/su is refused (paths)" || bad "badsu install: $R"
R=$(call launcher Install "{\"file\": \"badnet.raw\", \"build\": \"x\"}")
echo "$R" | grep -q 'OfferRefused' && echo "$R" | grep -q '"manifest"' && ok "a manifest asking for the network grant is refused (manifest)" || bad "badnet install: $R"
R=$(call launcher Install "{\"file\": \"hello.raw\", \"build\": \"0000\"}")
echo "$R" | grep -q 'OfferChanged' && ok "consent to another build is refused (OfferChanged)" || bad "wrong build: $R"
[ ! -e /var/lib/extensions/badsu.raw ] && [ ! -e /var/lib/extensions/badnet.raw ] \
    && ! systemd-sysext status --no-pager 2>&1 | grep -qE 'badsu|badnet' \
    && ok "nothing refused was copied or merged" || bad "a refused image left something behind"

echo "== install"
T0=$(date '+%Y-%m-%d %H:%M:%S')
R=$(call launcher Install "{\"file\": \"hello.raw\", \"build\": \"$BUILD\"}")
echo "        $R"
echo "$R" | grep -q '"id": *"hello"' && ok "installed hello" || bad "install: $R"
[ -f /var/lib/extensions/hello.raw ] && ok "/var/lib/extensions/hello.raw" || bad "no extension image"
[ ! -e $OFFERS/hello.raw ] && ok "the offer is consumed" || bad "offer still there"
systemd-sysext status --no-pager 2>&1 | grep -q hello && ok "systemd-sysext merged it: $(systemd-sysext status --no-pager | grep hello | tr -s ' ')" || bad "sysext status: $(systemd-sysext status --no-pager 2>&1)"
[ -f /usr/lib/vrx/apps/hello/manifest.toml ] && ok "its folder is at /usr/lib/vrx/apps/hello" || bad "no /usr/lib/vrx/apps/hello"
call launcher Applets | grep -q '"id": *"hello"' && ok "vrxhost's registry lists it (a tile)" || bad "not in Applets"
D=/etc/systemd/system/vrx-applet@hello.service.d/10-manifest.conf
if [ -f $D ]; then
    sed 's/^/        /' $D
    grep -q '^DynamicUser=yes' $D && ok "its unit runs as a dynamic user" || bad "no DynamicUser=yes"
    groups=$(sed -n 's/^SupplementaryGroups=//p' $D)
    extra=$(for g in $groups; do case $g in render|video) ;; *) echo $g ;; esac; done)
    [ -z "$extra" ] && ok "no grant group (SupplementaryGroups: ${groups:-none})" || bad "grant groups: $extra"
else
    bad "no drop-in at $D"
fi
call launcher Push '{"applet": "hello"}' >/dev/null
sleep 6
journalctl -u vrx-ui --since "$T0" --no-pager | grep -q "app 'hello' registered" \
    && ok "it started and registered with the compositor" || bad "hello never registered"
U=$(systemctl show -p User --value vrx-applet@hello.service)
P=$(systemctl show -p MainPID --value vrx-applet@hello.service)
UID_=$(awk '/^Uid:/{print $2}' /proc/$P/status 2>/dev/null)
[ -n "$UID_" ] && [ "$UID_" -ge 61184 ] && [ "$UID_" -le 65519 ] \
    && ok "it runs as dynamic uid $UID_" || bad "uid ${UID_:-?} (User=$U) is not a dynamic one"
G=$(awk '/^Groups:/{$1=""; print}' /proc/$P/status 2>/dev/null)
echo "        its groups: $G"
call launcher Home >/dev/null

echo "== uninstall"
R=$(call launcher Uninstall '{"applet": "hello"}')
echo "        $R"
echo "$R" | grep -q '"error"' && bad "uninstall: $R" || ok "uninstalled hello"
[ ! -e /var/lib/extensions/hello.raw ] && ok "the extension image is gone" || bad "image remains"
systemd-sysext status --no-pager 2>&1 | grep -q hello && bad "still merged" || ok "systemd-sysext no longer lists it"
[ ! -e /usr/lib/vrx/apps/hello ] && ok "its folder is gone from /usr" || bad "/usr/lib/vrx/apps/hello remains"
[ ! -e $D ] && ok "its drop-in is gone" || bad "drop-in remains"
call launcher Applets | grep -q '"id": *"hello"' && bad "still in Applets" || ok "the registry no longer lists it"
R=$(call launcher Uninstall '{"applet": "clock"}')
echo "$R" | grep -q 'NotInstalled' && ok "a built-in cannot be uninstalled (NotInstalled)" || bad "uninstall clock: $R"

# as it was
rm -f $OFFERS/hello.raw $OFFERS/badsu.raw $OFFERS/badnet.raw /tmp/hello.raw /tmp/badsu.raw /tmp/badnet.raw /tmp/inst.py
[ "$had_offers" = no ] && rmdir $OFFERS 2>/dev/null  # tmpfiles makes it on an image with this vrxhost
echo
[ "$fails" -eq 0 ] && echo "install-check: all passed" || { echo "install-check: $fails failed"; exit 1; }
EOF
