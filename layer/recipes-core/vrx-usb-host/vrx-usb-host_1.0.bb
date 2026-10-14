# vrx's USB host side (plan 0019 D8): a drive plugged into the board is
# mounted read-only under /run/vrx/usb by udev and systemd-mount, the
# pattern systemd-mount(1) documents; vrxhost hears the rest from the
# kernel's uevents. meta-vrx's packagegroup-vrx-usb installs this where the
# image allows storage (VRX_USB_CLASSES); nothing in vrx-linux pulls it in.
# The group vrx-usb-media is vrx-policy's (grants.conf, usb-media).
#
# SPDX-License-Identifier: MIT

SUMMARY = "vrx USB host: drives mounted read-only"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://80-vrx-usb-media.rules file://vrx-usb-mount file://vrx-usb-host.conf"
S = "${UNPACKDIR}"

inherit allarch

do_configure[noexec] = "1"
do_compile[noexec] = "1"
do_install() {
    install -D -m 0644 ${UNPACKDIR}/80-vrx-usb-media.rules ${D}${nonarch_base_libdir}/udev/rules.d/80-vrx-usb-media.rules
    install -D -m 0755 ${UNPACKDIR}/vrx-usb-mount ${D}${libexecdir}/vrx/vrx-usb-mount
    install -D -m 0644 ${UNPACKDIR}/vrx-usb-host.conf ${D}${nonarch_libdir}/tmpfiles.d/vrx-usb-host.conf
}

FILES:${PN} = "${nonarch_base_libdir}/udev/rules.d/80-vrx-usb-media.rules \
               ${libexecdir}/vrx/vrx-usb-mount \
               ${nonarch_libdir}/tmpfiles.d/vrx-usb-host.conf"
# systemd-mount is in systemd's main package; udev reads the rule; the
# group comes from vrx-policy
RDEPENDS:${PN} = "systemd udev vrx-policy"
