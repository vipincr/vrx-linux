#
# vrx-matter: the device on a Matter fabric (plan 0015). rs-matter in its
# own sandboxed process; vrxhost holds the rules and connects to it. Rides
# only on an image with VRX_MATTER = "1" (packagegroup-vrx-linux).
#
# SPDX-License-Identifier: MIT
#
require recipes-core/vrx-linux-source.inc

SUMMARY = "vrx-matter: the device on a Matter fabric"
SECTION = "core"
LICENSE = "MIT"

inherit cargo systemd useradd

SRC_URI += "file://vrx-matter.service \
           file://vrx-matter-bluetooth.conf \
           file://vrx-matter-bluetooth.service.conf \
           "

CARGO_SRC_DIR = "rust/matter"
CARGO_LOCK_PATH = "${S}/Cargo.lock"

# after SRC_URI: the crates manifest appends to it (see vrxhost_git.bb)
require recipes-core/vrx-workspace-crates.inc

# G042 (plan 0015 D11): the test attestation (the SDK's published test
# PAA, PAI and DAC, the crate's default feature) is for a debug image
# only. A release image needs the owner's factory data, which v1 does not
# load yet, so a release build with Matter stops here rather than ship a
# device that attests with keys anyone can download.
python () {
    if (d.getVar('VRX_MATTER') or '').strip() != '1':
        return
    if vrx_debug(d):
        return
    if not (d.getVar('VRX_MATTER_FACTORY_DATA') or '').strip():
        bb.fatal("VRX_MATTER = \"1\" on a release image (VRX_DEBUG != \"1\") needs VRX_MATTER_FACTORY_DATA: the test attestation is refused (G042)")
    bb.fatal("VRX_MATTER_FACTORY_DATA is set, but vrx-matter does not load factory data yet (plan 0015 Open 2): a release image cannot carry Matter (G042)")
}

# D5: BLE commissioning only where the board has Bluetooth. The crate's
# `ble` feature carries BlueZ's GATT transport and the QR code's Bluetooth
# bit; without it the device pairs on the network only. cargo.bbclass
# hands PACKAGECONFIG_CONFARGS to cargo build. The test attestation is
# the debug-image half (G042 above): the crate's default feature list is
# empty, so a release build carries no attestation because none was
# asked for, and the G042 check above still refuses a release build
# with Matter until factory data loads.
PACKAGECONFIG ??= "test-attestation-debug ${@bb.utils.filter('MACHINE_FEATURES', 'bluetooth', d)}"
PACKAGECONFIG[test-attestation-debug] = "${@'--features test-attestation' if vrx_debug(d) else ''}"
PACKAGECONFIG[bluetooth] = "--features ble,,,bluez5"

do_install() {
    install -D -m 0755 ${B}/target/${RUST_TARGET_SYS}/release/vrx-matter ${D}${bindir}/vrx-matter
    install -D -m 0644 ${UNPACKDIR}/vrx-matter.service ${D}${systemd_system_unitdir}/vrx-matter.service
    if ${@bb.utils.contains('PACKAGECONFIG', 'bluetooth', 'true', 'false', d)}; then
        # BlueZ on the bus for this user alone, and up before it
        install -D -m 0644 ${UNPACKDIR}/vrx-matter-bluetooth.conf ${D}${sysconfdir}/dbus-1/system.d/vrx-matter-bluetooth.conf
        install -D -m 0644 ${UNPACKDIR}/vrx-matter-bluetooth.service.conf ${D}${systemd_system_unitdir}/vrx-matter.service.d/bluetooth.conf
    fi
}

# The vrx-matter group is a grant's (grants.conf: matter = vrx-matter) and
# vrx-policy makes it on every image; -f makes this a no-op beside it.
USERADD_PACKAGES = "${PN}"
GROUPADD_PARAM:${PN} = "-r -f vrx-matter"
USERADD_PARAM:${PN} = "--system --no-create-home --home-dir /var/lib/vrx-matter --shell /sbin/nologin --gid vrx-matter vrx-matter"

FILES:${PN} = "${bindir}/vrx-matter ${systemd_system_unitdir}/vrx-matter.service \
               ${systemd_system_unitdir}/vrx-matter.service.d \
               ${sysconfdir}/dbus-1/system.d/vrx-matter-bluetooth.conf"
SYSTEMD_SERVICE:${PN} = "vrx-matter.service"
# mDNS through Avahi's D-Bus API (D3)
RDEPENDS:${PN} = "avahi-daemon"
