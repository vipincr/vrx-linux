# The groups vrx's system grants map to (plan 0008 D2, D16). Every group
# named in grants.conf exists on the image, so an applet unit naming one
# can always start; `-f` makes a group the base system already has (video,
# audio, input, dialout) a no-op. The D-Bus bus policy and polkit rules
# that make these groups mean something land with them (plan 0008 Part B).
#
# SPDX-License-Identifier: MIT

SUMMARY = "vrx grant groups"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

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

ALLOW_EMPTY:${PN} = "1"
do_configure[noexec] = "1"
do_compile[noexec] = "1"
do_install() {
    :
}
