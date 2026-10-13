# What vrx's system grants mean (plan 0008 D2, D16): the groups (every
# group named in grants.conf exists on the image, so an applet unit naming
# one can always start; `-f` makes a group the base system already has a
# no-op), the D-Bus bus policy (network, bluetooth), the polkit rules
# (hostname, power, usb, serve; time is meta-oe's datetime rule) and the
# backlight udev rule (display).
#
# SPDX-License-Identifier: MIT

SUMMARY = "vrx grant groups"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://zz-vrx.conf file://50-vrx.rules file://70-vrx-backlight.rules file://vrx-settings.conf"
S = "${UNPACKDIR}"

inherit allarch useradd

VRX_GRANTS_CONF = "${VRX_LINUX_LAYERDIR}/recipes-applets/vrx-applets/files/grants.conf"

def vrx_grant_groups(d):
    groups = []
    with open(d.getVar('VRX_GRANTS_CONF')) as f:
        for line in f:
            line = line.split('#', 1)[0].strip()
            if line:
                group = line.partition('=')[2].split()[0]
                if group not in groups:
                    groups.append(group)
    return "; ".join("-r -f %s" % g for g in groups)

USERADD_PACKAGES = "${PN}"
GROUPADD_PARAM:${PN} = "${@vrx_grant_groups(d)}"
# parse-time read: re-parse when the mapping changes
VRX_POLICY_GRANTS_STAMP := "${@bb.parse.mark_dependency(d, d.getVar('VRX_GRANTS_CONF'))}"

do_configure[noexec] = "1"
do_compile[noexec] = "1"
do_install() {
    install -D -m 0644 ${UNPACKDIR}/zz-vrx.conf ${D}${sysconfdir}/dbus-1/system.d/zz-vrx.conf
    # polkitd reads rules.d as its own user: 0644, directory 0755 is the
    # polkit recipe's
    install -D -m 0644 ${UNPACKDIR}/50-vrx.rules ${D}${datadir}/polkit-1/rules.d/50-vrx.rules
    install -D -m 0644 ${UNPACKDIR}/70-vrx-backlight.rules ${D}${nonarch_base_libdir}/udev/rules.d/70-vrx-backlight.rules
    install -D -m 0644 ${UNPACKDIR}/vrx-settings.conf ${D}${nonarch_libdir}/tmpfiles.d/vrx-settings.conf
}

FILES:${PN} = "${sysconfdir}/dbus-1/system.d/zz-vrx.conf \
               ${datadir}/polkit-1/rules.d/50-vrx.rules \
               ${nonarch_base_libdir}/udev/rules.d/70-vrx-backlight.rules \
               ${nonarch_libdir}/tmpfiles.d/vrx-settings.conf"
# polkit evaluates the rules; the time grant is meta-oe's own rule
RDEPENDS:${PN} = "polkit polkit-group-rule-datetime"
