#
# vrxhost: the applet OS daemon (plan 0007 part C). Registry scan
# (/apps + /system/defaults), applet supervision, the intent socket at
# /tmp/vrx/vrx.sock, the back trail.
#
# STATUS: skeleton — the recipe is finalized in the same change that
# registers this layer into the vrx build (see layer/README.md), which
# is when it first becomes parse-checkable. Until then: no SRCREV, no
# crates .inc, no build claim.
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
# pinned when the remote exists; crates .inc generated with
# cargo-bitbake in the same change
SRCREV = "INVALID-pin-when-remote-exists"

S = "${WORKDIR}/git"

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${B}/target/${RUST_TARGET_SYS}/release/vrxhost ${D}${bindir}/
    install -d ${D}${systemd_unitdir}/system
    install -m 0644 ${UNPACKDIR}/vrxhost.service ${D}${systemd_unitdir}/system/
}

FILES:${PN} = "${bindir}/vrxhost ${systemd_unitdir}/system/vrxhost.service"

SYSTEMD_SERVICE:${PN} = "vrxhost.service"
