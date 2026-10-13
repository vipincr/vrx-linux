# The source every built-in applet builds from, whatever its runtime: the
# Flutter applets (vrx-applet.inc) and the Rust ones (vrx-applet-stt.bb).
#
# SPDX-License-Identifier: MIT

HOMEPAGE = "https://github.com/vipincr/vrx-linux"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://LICENSE;md5=a16ed7a590c33c21c11c7627d9b79efd"

SRC_URI = "git://github.com/vipincr/vrx-linux.git;protocol=https;branch=master"
# The one source commit every built-in applet builds from (they share a
# checkout: applets/ plus flutter/vrx_kit and rust/sdk); bumped with every
# change to any of them, the same flow as vrxhost's SRCREV.
SRCREV = "2452cb0e603e6c226e3b3b6c3943d616ee3c8816"
PV = "1.0+git${SRCPV}"

COMPATIBLE_MACHINE = "^vrxboard-"
