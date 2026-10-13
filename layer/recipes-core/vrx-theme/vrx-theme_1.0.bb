# vrx's look (plan 0009): what kind of panel this device has, the scheme it
# draws until its settings name another, and the unit that snapshots the
# choice once per boot. vrx_kit reads /usr/lib/vrx/display-class and
# /run/vrx/theme.conf (bootColors); Settings writes scheme= and polarity=
# into /etc/vrx/settings/vrx.conf.
#
#   VRX_DISPLAY_CLASS  lcd_colour | lcd_grey | epaper_grey | epaper_mono
#                      (the vrx UI standard's [class.*]; a carrier with a
#                      panel declares it)
#   VRX_UI_SCHEME      1..20, the standard's schemes
#   VRX_UI_POLARITY    dark | light
#
# SPDX-License-Identifier: MIT

SUMMARY = "vrx look: the display class, the default scheme and its boot snapshot"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://vrx-theme-snapshot file://vrx-theme.service"
S = "${UNPACKDIR}"

inherit systemd

# the class is the machine's (its carrier's panel)
PACKAGE_ARCH = "${MACHINE_ARCH}"

VRX_DISPLAY_CLASS ??= "lcd_colour"
VRX_UI_SCHEME ??= "12"
VRX_UI_POLARITY ??= "dark"

python () {
    cls = d.getVar('VRX_DISPLAY_CLASS')
    if cls not in ('lcd_colour', 'lcd_grey', 'epaper_grey', 'epaper_mono'):
        bb.fatal("VRX_DISPLAY_CLASS = '%s': must be lcd_colour, lcd_grey, epaper_grey or epaper_mono (the vrx UI standard's classes)" % cls)
    scheme = d.getVar('VRX_UI_SCHEME')
    if not scheme.isdigit() or not 1 <= int(scheme) <= 20:
        bb.fatal("VRX_UI_SCHEME = '%s': must be 1 to 20 (the vrx UI standard's schemes)" % scheme)
    if d.getVar('VRX_UI_POLARITY') not in ('dark', 'light'):
        bb.fatal("VRX_UI_POLARITY = '%s': must be dark or light" % d.getVar('VRX_UI_POLARITY'))
}

SYSTEMD_SERVICE:${PN} = "vrx-theme.service"

do_configure[noexec] = "1"
do_compile[noexec] = "1"
do_install() {
    install -d ${D}${nonarch_libdir}/vrx
    echo "${VRX_DISPLAY_CLASS}" > ${D}${nonarch_libdir}/vrx/display-class
    printf 'scheme=%s\npolarity=%s\n' "${VRX_UI_SCHEME}" "${VRX_UI_POLARITY}" > ${D}${nonarch_libdir}/vrx/theme-default.conf
    install -D -m 0755 ${UNPACKDIR}/vrx-theme-snapshot ${D}${libexecdir}/vrx/vrx-theme-snapshot
    install -D -m 0644 ${UNPACKDIR}/vrx-theme.service ${D}${systemd_system_unitdir}/vrx-theme.service
}

FILES:${PN} = "${nonarch_libdir}/vrx/display-class ${nonarch_libdir}/vrx/theme-default.conf \
               ${libexecdir}/vrx/vrx-theme-snapshot ${systemd_system_unitdir}/vrx-theme.service"
