#
# vrxhost: the applet OS daemon (plan 0007 part C). Registry scan
# (/system/defaults, and /usr/lib/vrx/apps where systemd-sysext merges
# installed applets), applet supervision through systemd, io.vrx.Host on
# /run/vrx, the back trail, installs (plan 0011 D16).
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
           file://vrxhost-tmpfiles.conf \
           file://vrx-applet@.service \
           "
SRCREV = "0b538a6d91bad3f695cf84bcefb5bf224bdd40e8"

# the workspace member this recipe builds (the root manifest is the
# workspace, not a package); the lock is the workspace's, not the
# member's
CARGO_SRC_DIR = "rust/host"
CARGO_LOCK_PATH = "${S}/Cargo.lock"

# AFTER the SRC_URI assignment above: the crates manifest appends to
# it, and a require before the assignment would be wiped by the plain
# `=` (bitbake parse order). Generated from Cargo.lock:
#   cargo xtask crates-inc   (one manifest for the whole workspace)
require recipes-core/vrx-workspace-crates.inc

# S is NOT restated: wrynose's bitbake.conf sets it correctly for git
# sources, and a recipe-side S = "${WORKDIR}/git" is a hard error.

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${B}/target/${RUST_TARGET_SYS}/release/vrxhost ${D}${bindir}/
    install -d ${D}${systemd_unitdir}/system
    install -m 0644 ${UNPACKDIR}/vrxhost.service ${D}${systemd_unitdir}/system/
    install -m 0644 ${UNPACKDIR}/vrx-applet@.service ${D}${systemd_unitdir}/system/
    install -d ${D}${nonarch_libdir}/tmpfiles.d
    install -m 0644 ${UNPACKDIR}/vrxhost-tmpfiles.conf ${D}${nonarch_libdir}/tmpfiles.d/vrxhost.conf
}

# The vrx group: every applet user is a member (vrx-applet@.service's
# SupplementaryGroups), which is what lets applets reach the compositor's
# socket and io.vrx.Host. Applets run as their own users (plan 0008 D1),
# created by their packages; there is no shared applet user any more.
inherit useradd
USERADD_PACKAGES = "${PN}"
GROUPADD_PARAM:${PN} = "-r vrx"

FILES:${PN} = "${bindir}/vrxhost ${systemd_unitdir}/system/vrxhost.service \
               ${systemd_unitdir}/system/vrx-applet@.service \
               ${nonarch_libdir}/tmpfiles.d/vrxhost.conf"

SYSTEMD_SERVICE:${PN} = "vrxhost.service"
