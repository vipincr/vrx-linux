# vrx's USB modes (plan 0008 D11): the console (ACM, always, from boot)
# and file sharing (a mass-storage disk image on /data added beside it),
# built in configfs by one script, one unit each. Boards without a UDC skip both
# (ConditionPathExistsGlob). A board whose kernel command line binds a
# legacy gadget (g_serial) to the UDC must drop it: one owner per UDC.
#
# Built, not libusbgx (the plan's first choice): the gadget needs values a
# static schema cannot hold (the board's serial number, the image path),
# and libusbgx-examples would bring a second enabled gadget service.
#
# SPDX-License-Identifier: MIT

SUMMARY = "vrx USB: the console and file sharing"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://vrx-usb-gadget file://vrx-usb-console.service file://vrx-usb-files.service"
S = "${UNPACKDIR}"

inherit allarch systemd

SYSTEMD_SERVICE:${PN} = "vrx-usb-console.service vrx-usb-files.service"
# console is wanted at boot (its [Install]); files has no [Install]
SYSTEMD_AUTO_ENABLE = "enable"

do_configure[noexec] = "1"
do_compile[noexec] = "1"
do_install() {
    install -D -m 0755 ${UNPACKDIR}/vrx-usb-gadget ${D}${libexecdir}/vrx/vrx-usb-gadget
    install -D -m 0644 ${UNPACKDIR}/vrx-usb-console.service ${D}${systemd_system_unitdir}/vrx-usb-console.service
    install -D -m 0644 ${UNPACKDIR}/vrx-usb-files.service ${D}${systemd_system_unitdir}/vrx-usb-files.service
}

FILES:${PN} = "${libexecdir}/vrx/vrx-usb-gadget ${systemd_system_unitdir}/vrx-usb-*.service"
# mkfs.vfat makes the files image; modprobe loads libcomposite
RDEPENDS:${PN} = "dosfstools kmod"
