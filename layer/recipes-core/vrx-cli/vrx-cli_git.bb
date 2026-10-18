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
SECTION = "devel"
LICENSE = "MIT"

inherit cargo

# the first commit with `vrx unit`; bumped with vrxhost's when rust/cli or
# rust/protocol changes
require recipes-core/vrx-linux-source.inc

CARGO_SRC_DIR = "rust/cli"
CARGO_LOCK_PATH = "${S}/Cargo.lock"

# after SRC_URI: the crates manifest appends to it (see vrxhost_git.bb)
require recipes-core/vrx-workspace-crates.inc

do_install() {
    install -D -m 0755 ${B}/target/${RUST_TARGET_SYS}/release/vrx ${D}${bindir}/vrx
}

FILES:${PN} = "${bindir}/vrx"

BBCLASSEXTEND = "native"
