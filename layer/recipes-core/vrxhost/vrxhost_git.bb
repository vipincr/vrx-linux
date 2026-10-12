#
# vrxhost: the applet OS daemon (plan 0007 part C). Registry scan
# (/apps + /system/defaults), applet supervision, the intent socket at
# /tmp/vrx/vrx.sock, the back trail.
#
# SPDX-License-Identifier: MIT
#

SUMMARY = "vrxhost: the vrx applet OS daemon (registry, supervisor, intents, trail)"
HOMEPAGE = "https://github.com/vipincr/vrx-linux"
SECTION = "core"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://LICENSE;md5=a16ed7a590c33c21c11c7627d9b79efd"

inherit cargo systemd

SRC_URI = "git://github.com/vipincr/vrx-linux.git;protocol=https;branch=master \
           file://vrxhost.service \
           "
SRCREV = "3f008684aaa2eea040177eaae234ec5a45d829c8"

# the workspace member this recipe builds (the root manifest is the
# workspace, not a package); the lock is the workspace's, not the
# member's
CARGO_SRC_DIR = "rust/host"
CARGO_LOCK_PATH = "${S}/Cargo.lock"

# AFTER the SRC_URI assignment above: the crates manifest appends to
# it, and a require before the assignment would be wiped by the plain
# `=` (bitbake parse order). Generated from Cargo.lock:
#   cargo run -p vrx-xtask -- crates-inc vrx-host layer/recipes-core/vrxhost/vrxhost-crates.inc
require vrxhost-crates.inc

# S is NOT restated: wrynose's bitbake.conf sets it correctly for git
# sources, and a recipe-side S = "${WORKDIR}/git" is a hard error.

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${B}/target/${RUST_TARGET_SYS}/release/vrxhost ${D}${bindir}/
    install -d ${D}${systemd_unitdir}/system
    install -m 0644 ${UNPACKDIR}/vrxhost.service ${D}${systemd_unitdir}/system/
}

FILES:${PN} = "${bindir}/vrxhost ${systemd_unitdir}/system/vrxhost.service"

SYSTEMD_SERVICE:${PN} = "vrxhost.service"
