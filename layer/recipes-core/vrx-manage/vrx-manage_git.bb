#
# vrx-manage: the management page and its JSON API (plan 0008 Part G),
# served while the Manage applet asks. The page is evrx-rt's manage-ui,
# built and vendored in vrx-linux's manage-ui/.
#
# SPDX-License-Identifier: MIT
#

SUMMARY = "vrx-manage: the management page and its JSON API"
SECTION = "core"
LICENSE = "MIT"

inherit cargo systemd

           "

CARGO_SRC_DIR = "rust/manage"
CARGO_LOCK_PATH = "${S}/Cargo.lock"

# after SRC_URI: the crates manifest appends to it (see vrxhost_git.bb)
require recipes-core/vrx-linux-source.inc
SRC_URI += "file://vrx-manage.service"

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
# ip and journalctl (df is busybox, in every image) answer /api/status and
# /api/log; vrx-policy creates vrx-update, the group of the uploads'
# directory (vrxhost's tmpfiles)
RDEPENDS:${PN} = "iproute2 systemd vrx-policy"
