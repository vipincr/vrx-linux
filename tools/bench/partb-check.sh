#!/bin/sh
# Plan 0008 Part B on a freshly flashed board: persistence, one owner per
# job, and grants enforced by the services themselves (G017's bench row).
#
#   tools/bench/partb-check.sh <board-host> [after-reboot]
#
# Read-only except: it sets the time zone and the pretty hostname (both
# restored at the end) to prove the grants and, with `after-reboot`,
# that they persisted. It never powers the board off: CanPowerOff shows
# the authorization without acting.
set -u
HOST=$1 PHASE=${2:-first}
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "root@$HOST" PHASE="$PHASE" sh -s <<'EOF'
fails=0
ok()   { echo "  ok    $*"; }
bad()  { echo "  FAIL  $*"; fails=$((fails + 1)); }
check() { desc=$1; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi; }

echo "== persistence (D4)"
check "/etc is an overlay"            awk '$2=="/etc" && $3=="overlay" {f=1} END {exit !f}' /proc/mounts
check "/var/lib is an overlay"        awk '$2=="/var/lib" && $3=="overlay" {f=1} END {exit !f}' /proc/mounts
check "/data is mounted"              awk '$2=="/data" {f=1} END {exit !f}' /proc/mounts
check "/data grew past 1 GiB"         sh -c '[ $(df -k /data | awk "NR==2 {print \$2}") -gt 1048576 ]'
check "vrx-data-setup ran"            systemctl is-active vrx-data-setup.service

echo "== one owner per job (D6, D7)"
for u in systemd-networkd systemd-resolved ofono neard; do
    check "$u absent" sh -c "! systemctl cat $u.service"
done
check "timesyncd active"              systemctl is-active systemd-timesyncd
check "connman NTP off"               sh -c 'connmanctl clock | grep -q "TimeUpdates = manual"'
check "tzdata present"                test -e /usr/share/zoneinfo/Asia/Kolkata
check "polkit active"                 systemctl is-active polkit

echo "== grants, enforced by the services (G017)"
# launcher holds apps only: every system write refused
check "no grant: connman refused"     sh -c '! su -s /bin/sh vrx-launcher -c "busctl call net.connman / net.connman.Manager GetServices"'
check "no grant: BlueZ refused"       sh -c '! su -s /bin/sh vrx-launcher -c "busctl set-property org.bluez /org/bluez/hci0 org.bluez.Adapter1 Pairable b false"'
check "no grant: zone refused"        sh -c '! su -s /bin/sh vrx-launcher -c "busctl call org.freedesktop.timedate1 /org/freedesktop/timedate1 org.freedesktop.timedate1 SetTimezone sb UTC false"'
check "no grant: hostname refused"    sh -c '! su -s /bin/sh vrx-launcher -c "busctl call org.freedesktop.hostname1 /org/freedesktop/hostname1 org.freedesktop.hostname1 SetPrettyHostname sb x false"'
check "no grant: power-off denied"    sh -c 'su -s /bin/sh vrx-launcher -c "busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager CanPowerOff" | grep -qv "\"yes\""'
# settings holds network, bluetooth, time, hostname, power
check "network grant: connman"        su -s /bin/sh vrx-settings -c "busctl call net.connman / net.connman.Manager GetServices"
check "bluetooth grant: BlueZ"        su -s /bin/sh vrx-settings -c "busctl get-property org.bluez /org/bluez/hci0 org.bluez.Adapter1 Powered"
check "power grant: power-off yes"    sh -c 'su -s /bin/sh vrx-settings -c "busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager CanPowerOff" | grep -q "\"yes\""'
if [ "$PHASE" = first ]; then
    check "time grant: set zone"      su -s /bin/sh vrx-settings -c "busctl call org.freedesktop.timedate1 /org/freedesktop/timedate1 org.freedesktop.timedate1 SetTimezone sb Asia/Kolkata false"
    check "hostname grant: set name"  su -s /bin/sh vrx-settings -c "busctl call org.freedesktop.hostname1 /org/freedesktop/hostname1 org.freedesktop.hostname1 SetPrettyHostname sb vrx-bench false"
    echo "   (reboot, then run again with: after-reboot)"
else
    check "zone survived the reboot"  sh -c 'readlink /etc/localtime | grep -q Asia/Kolkata'
    check "name survived the reboot"  sh -c 'hostnamectl | grep -q vrx-bench'
    check "zone change landed in /data" test -e /data/overlay-etc/upper/localtime
    timedatectl set-timezone UTC; hostnamectl set-hostname --pretty ""
fi

echo "== $fails failure(s)"
exit $fails
EOF
