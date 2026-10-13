# A built-in Flutter applet from this repo's applets/<id>, AOT-built by
# meta-flutter's flutter-app pipeline and installed where vrxhost's
# registry scans built-ins (plan 0007 part L; amendment C):
#
#   /system/defaults/<id>/manifest.toml
#   /system/defaults/<id>/<flutter-sdk-version>/release/{data,lib}
#
# vrxhost runs it as `flutter-vrx --release --app <that release dir>`,
# as the vrx user. A recipe sets VRX_APPLET (the manifest id, which is
# also the directory under applets/) and SUMMARY; nothing else.
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
SRCREV = "db0824021da6d44c4f7b733e5514bc0bbd70463f"
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

FILES:${PN} += "${FLUTTER_INSTALL_DIR}"
# flutter-vrx is the runtime that hosts the bundle
RDEPENDS:${PN} += "flutter-vrx"
