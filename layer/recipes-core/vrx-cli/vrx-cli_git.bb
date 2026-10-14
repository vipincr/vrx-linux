#
# vrx-cli: the vrx command-line tool. The image build uses its native
# variant: `vrx unit` writes every built-in applet's unit drop-in and
# settings defaults from its manifest (vrx-applet-unit.bbclass, plan 0011
# D17), with the generator vrxhost uses when it installs an applet. No
# image ships the target package.
#
# SPDX-License-Identifier: MIT
#

SUMMARY = "vrx: the applet tool (new, build, pack, unit, test)"
HOMEPAGE = "https://github.com/vipincr/vrx-linux"
SECTION = "devel"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://LICENSE;md5=a16ed7a590c33c21c11c7627d9b79efd"

inherit cargo

SRC_URI = "git://github.com/vipincr/vrx-linux.git;protocol=https;branch=master"
# the first commit with `vrx unit`; bumped with vrxhost's when rust/cli or
# rust/protocol changes
SRCREV = "1e1447fc382ef01825aa84241204645aafda6417"

CARGO_SRC_DIR = "rust/cli"
CARGO_LOCK_PATH = "${S}/Cargo.lock"

# after SRC_URI: the crates manifest appends to it (see vrxhost_git.bb)
require recipes-core/vrx-workspace-crates.inc

do_install() {
    install -D -m 0755 ${B}/target/${RUST_TARGET_SYS}/release/vrx ${D}${bindir}/vrx
}

FILES:${PN} = "${bindir}/vrx"

BBCLASSEXTEND = "native"
