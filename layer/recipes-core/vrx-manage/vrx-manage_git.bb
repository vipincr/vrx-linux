#
# vrx-manage: the management page and its JSON API (plan 0008 Part G),
# served while the Manage applet asks. The page is evrx-rt's manage-ui,
# built and vendored in vrx-linux's manage-ui/.
#
# SPDX-License-Identifier: MIT
#

SUMMARY = "vrx-manage: the management page and its JSON API"
HOMEPAGE = "https://github.com/vipincr/vrx-linux"
SECTION = "core"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://LICENSE;md5=a16ed7a590c33c21c11c7627d9b79efd"

inherit cargo systemd

SRC_URI = "git://github.com/vipincr/vrx-linux.git;protocol=https;branch=master \
           file://vrx-manage.service \
           "
SRCREV = "877a3dfb300fe7b506601c69e8152248e471da4d"

CARGO_SRC_DIR = "rust/manage"
CARGO_LOCK_PATH = "${S}/Cargo.lock"

# after SRC_URI: the crates manifest appends to it (see vrxhost_git.bb)
require recipes-core/vrx-workspace-crates.inc

do_install() {
    install -D -m 0755 ${B}/target/${RUST_TARGET_SYS}/release/vrx-manage ${D}${bindir}/vrx-manage
    install -D -m 0644 ${UNPACKDIR}/vrx-manage.service ${D}${systemd_system_unitdir}/vrx-manage.service
    install -d ${D}${datadir}/vrx/manage-ui
    cp -R --no-preserve=ownership ${S}/manage-ui/dist/. ${D}${datadir}/vrx/manage-ui/
}

FILES:${PN} = "${bindir}/vrx-manage ${systemd_system_unitdir}/vrx-manage.service ${datadir}/vrx/manage-ui"

# started by the Manage applet, never at boot
SYSTEMD_SERVICE:${PN} = "vrx-manage.service"
SYSTEMD_AUTO_ENABLE = "disable"
# ip and journalctl (df is busybox, in every image) answer /api/status and /api/log
RDEPENDS:${PN} = "iproute2 systemd"
