# The vrx-linux source, named once (review 2026-10-17, KRN-04): every
# recipe that builds from the repository requires this file and adds only
# what it unpacks beside the checkout (files, the crates manifest).
# SPDX-License-Identifier: MIT

HOMEPAGE = "https://github.com/vipincr/vrx-linux"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://LICENSE;md5=a16ed7a590c33c21c11c7627d9b79efd"

SRC_URI = "git://github.com/vipincr/vrx-linux.git;protocol=https;branch=master"
SRCREV = "${VRX_LINUX_SRCREV}"
