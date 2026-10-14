#
# vrx-matter: the device on a Matter fabric (plan 0015). rs-matter in its
# own sandboxed process; vrxhost holds the rules and connects to it. Rides
# only on an image with VRX_MATTER = "1" (packagegroup-vrx-linux).
#
# SPDX-License-Identifier: MIT
#

SUMMARY = "vrx-matter: the device on a Matter fabric"
HOMEPAGE = "https://github.com/vipincr/vrx-linux"
SECTION = "core"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://LICENSE;md5=a16ed7a590c33c21c11c7627d9b79efd"

inherit cargo systemd useradd

SRC_URI = "git://github.com/vipincr/vrx-linux.git;protocol=https;branch=master \
           file://vrx-matter.service \
           "
SRCREV = "a4ad136ea399ff5de6e7d7b4cb528f343d9901ab"

CARGO_SRC_DIR = "rust/matter"
CARGO_LOCK_PATH = "${S}/Cargo.lock"

# after SRC_URI: the crates manifest appends to it (see vrxhost_git.bb)
require recipes-core/vrx-workspace-crates.inc

# G042 (plan 0015 D11): the test attestation (the SDK's published test
# PAA, PAI and DAC, the crate's default feature) is for a debug image
# only. A release image needs the owner's factory data, which v1 does not
# load yet, so a release build with Matter stops here rather than ship a
# device that attests with keys anyone can download.
python () {
    if (d.getVar('VRX_MATTER') or '').strip() != '1':
        return
    if d.getVar('VRX_DEBUG') == '1':
        return
    if not (d.getVar('VRX_MATTER_FACTORY_DATA') or '').strip():
        bb.fatal("VRX_MATTER = \"1\" on a release image (VRX_DEBUG != \"1\") needs VRX_MATTER_FACTORY_DATA: the test attestation is refused (G042)")
    bb.fatal("VRX_MATTER_FACTORY_DATA is set, but vrx-matter does not load factory data yet (plan 0015 Open 2): a release image cannot carry Matter (G042)")
}

do_install() {
    install -D -m 0755 ${B}/target/${RUST_TARGET_SYS}/release/vrx-matter ${D}${bindir}/vrx-matter
    install -D -m 0644 ${UNPACKDIR}/vrx-matter.service ${D}${systemd_system_unitdir}/vrx-matter.service
}

# The vrx-matter group is a grant's (grants.conf: matter = vrx-matter) and
# vrx-policy makes it on every image; -f makes this a no-op beside it.
USERADD_PACKAGES = "${PN}"
GROUPADD_PARAM:${PN} = "-r -f vrx-matter"
USERADD_PARAM:${PN} = "--system --no-create-home --home-dir /var/lib/vrx-matter --shell /sbin/nologin --gid vrx-matter vrx-matter"

FILES:${PN} = "${bindir}/vrx-matter ${systemd_system_unitdir}/vrx-matter.service"
SYSTEMD_SERVICE:${PN} = "vrx-matter.service"
# mDNS through Avahi's D-Bus API (D3)
RDEPENDS:${PN} = "avahi-daemon"
