# A built-in Flutter applet from this repo's applets/<id>, AOT-built by
# meta-flutter's flutter-app pipeline and installed where vrxhost's
# registry scans built-ins (plan 0007 part L; amendment C):
#
#   /system/defaults/<id>/manifest.toml
#   /system/defaults/<id>/<flutter-sdk-version>/release/{data,lib}
#
# It runs as its own user vrx-<id> in vrx-applet@<id>.service (plan 0008
# D1); vrx-applet-unit.bbclass generates the unit's drop-in from the
# manifest. A recipe sets VRX_APPLET (the manifest id, which is also the
# directory under applets/) and SUMMARY; nothing else.
#
# SPDX-License-Identifier: MIT

HOMEPAGE = "https://github.com/vipincr/vrx-linux"
SECTION = "graphics"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://LICENSE;md5=a16ed7a590c33c21c11c7627d9b79efd"

SRC_URI = "git://github.com/vipincr/vrx-linux.git;protocol=https;branch=master"
# The one source commit every built-in applet builds from (they share a
# checkout: applets/ plus flutter/vrx_kit); bumped with every change to
# either, the same flow as vrxhost's SRCREV.
SRCREV = "62a2edef51a97f24a2c401c4e05ee9ccf00a84fc"
PV = "1.0+git${SRCPV}"

COMPATIBLE_MACHINE = "^vrxboard-"

VRX_APPLET ?= ""
python () {
    if not d.getVar('VRX_APPLET'):
        bb.fatal("%s: set VRX_APPLET to the applet id" % d.getVar('PN'))
}

# pubspec name is <id>_applet (applets/<id>/pubspec.yaml)
PUBSPEC_APPNAME = "${VRX_APPLET}_applet"
FLUTTER_APPLICATION_PATH = "applets/${VRX_APPLET}"
FLUTTER_APPLICATION_INSTALL_PREFIX = "/system/defaults"
FLUTTER_APPLICATION_INSTALL_SUFFIX = "${VRX_APPLET}"

inherit flutter-app

do_install:append() {
    install -m 0644 ${S}/applets/${VRX_APPLET}/manifest.toml \
        ${D}${FLUTTER_INSTALL_DIR}/manifest.toml
}

# The unit drop-in and the applet's user: vrx-applet-unit.bbclass, from the
# manifest installed above.
VRX_APPLET_DIR = "${FLUTTER_INSTALL_DIR}"
VRX_FLUTTER_BUNDLE = "${FLUTTER_INSTALL_DIR}/${FLUTTER_SDK_VERSION}/release"
inherit vrx-applet-unit

FILES:${PN} += "${FLUTTER_INSTALL_DIR}"
# flutter-vrx is the runtime that hosts the bundle; vrx_kit draws its
# icons from the system's Material Symbols and its text in Roboto
RDEPENDS:${PN} += "flutter-vrx ttf-material-symbols ttf-roboto"
