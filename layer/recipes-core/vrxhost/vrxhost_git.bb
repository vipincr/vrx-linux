#
# vrxhost: the applet OS daemon (plan 0007 part C). Registry scan
# (/apps + /system/defaults), applet supervision, the intent socket at
# /tmp/vrx/vrx.sock, the back trail.
#
#
# SPDX-License-Identifier: MIT
#

SUMMARY = "vrxhost: the vrx applet OS daemon (registry, supervisor, intents, trail)"
HOMEPAGE = "https://github.com/vipincr/vrx-linux"
SECTION = "core"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://LICENSE;md5=a16ed7a590c33c21c11c7627d9b79efd"

inherit cargo systemd

# the crates manifest is generated from Cargo.lock:
#   cargo run -p vrx-xtask -- crates-inc vrx-host layer/recipes-core/vrxhost/vrxhost-crates.inc
require vrxhost-crates.inc

SRC_URI = "git://github.com/vipincr/vrx-linux.git;protocol=https;branch=master \
           file://vrxhost.service \
           "
SRCREV = "1edffa2d9ded4772e8f8ed90806e4a4dc78d2443"

S = "${WORKDIR}/git"

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${B}/target/${RUST_TARGET_SYS}/release/vrxhost ${D}${bindir}/
    install -d ${D}${systemd_unitdir}/system
    install -m 0644 ${UNPACKDIR}/vrxhost.service ${D}${systemd_unitdir}/system/
}

FILES:${PN} = "${bindir}/vrxhost ${systemd_unitdir}/system/vrxhost.service"

SYSTEMD_SERVICE:${PN} = "vrxhost.service"
