#
# vrxhost: the applet OS daemon (plan 0007 part C). Registry scan
# (/system/defaults, and /usr/lib/vrx/apps where systemd-sysext merges
# installed applets), applet supervision through systemd, io.vrx.Host on
# /run/vrx, the back trail, installs (plan 0011 D16) and their policy
# (plan 0013 D3).
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
           file://vrx-install.service \
           file://vrx-wake@.service \
           file://vrx-wakealarm.service \
           file://50-vrx-signed.conf \
           file://vrx-kernel-verity.conf \
           "
SRCREV = "a4ad136ea399ff5de6e7d7b4cb528f343d9901ab"

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
    install -m 0644 ${UNPACKDIR}/vrx-install.service ${D}${systemd_unitdir}/system/
    install -m 0644 ${UNPACKDIR}/vrx-wake@.service ${D}${systemd_unitdir}/system/
    install -m 0644 ${UNPACKDIR}/vrx-wakealarm.service ${D}${systemd_unitdir}/system/
    install -d ${D}${nonarch_libdir}/tmpfiles.d
    install -m 0644 ${UNPACKDIR}/vrxhost-tmpfiles.conf ${D}${nonarch_libdir}/tmpfiles.d/vrxhost.conf

    # the install policy (plan 0013 D3, vrx_protocol::sysext): whether this
    # image installs applets at all, and, in a release image that does,
    # systemd-sysext's own policy requiring a kernel-verified signature
    install -d ${D}${nonarch_libdir}/vrx
    printf '# written by vrxhost'"'"'s recipe from VRX_INSTALLS (plan 0013 D3)\ninstalls=%s\n' \
        "${@vrx_installs(d)}" > ${D}${nonarch_libdir}/vrx/install.conf
    if [ "${@vrx_installs(d)}" = yes ] && [ "${VRX_DEBUG}" != 1 ]; then
        install -d ${D}${nonarch_libdir}/systemd/sysext.conf.d
        install -m 0644 ${UNPACKDIR}/50-vrx-signed.conf ${D}${nonarch_libdir}/systemd/sysext.conf.d/
    fi
    for unit in systemd-sysext.service systemd-sysext@.service; do
        install -d ${D}${systemd_unitdir}/system/$unit.d
        install -m 0644 ${UNPACKDIR}/vrx-kernel-verity.conf ${D}${systemd_unitdir}/system/$unit.d/
    done
}

# VRX_INSTALLS (meta-vrx's layer.conf): "1" lets the image install applets,
# "" builds one that installs nothing. Closed when unset. A release image
# that installs must carry VRX_INSTALL_CERT (meta-vrx's vrx-install-cert
# class refuses the build otherwise); a debug image (VRX_DEBUG = "1") also
# takes unsigned images, as the owner decided (2026-10-14).
def vrx_installs(d):
    v = (d.getVar('VRX_INSTALLS') or '').strip()
    if v not in ('1', ''):
        bb.fatal("VRX_INSTALLS must be '1' (install applets) or '' (none), got '%s'" % v)
    return 'yes' if v == '1' else 'no'

do_install[vardeps] += "VRX_INSTALLS VRX_DEBUG"

# The vrx group: every applet user is a member (vrx-applet@.service's
# SupplementaryGroups), which is what lets applets reach the compositor's
# socket and io.vrx.Host. Applets run as their own users (plan 0008 D1),
# created by their packages; there is no shared applet user any more.
inherit useradd
USERADD_PACKAGES = "${PN}"
GROUPADD_PARAM:${PN} = "-r vrx"

FILES:${PN} = "${bindir}/vrxhost ${systemd_unitdir}/system/vrxhost.service \
               ${systemd_unitdir}/system/vrx-applet@.service \
               ${systemd_unitdir}/system/vrx-install.service \
               ${systemd_unitdir}/system/vrx-wake@.service \
               ${systemd_unitdir}/system/vrx-wakealarm.service \
               ${systemd_unitdir}/system/systemd-sysext.service.d \
               ${systemd_unitdir}/system/systemd-sysext@.service.d \
               ${nonarch_libdir}/vrx/install.conf \
               ${nonarch_libdir}/systemd/sysext.conf.d \
               ${nonarch_libdir}/tmpfiles.d/vrxhost.conf"

SYSTEMD_SERVICE:${PN} = "vrxhost.service vrx-wakealarm.service"
