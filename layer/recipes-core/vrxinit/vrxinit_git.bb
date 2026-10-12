#
# vrxinit: PID 1 (plan 0007 part M). Mounts the basics, hands the
# system to systemd, keeps a console only when the kernel cmdline
# carries vrx.debug. Shipping the binary does NOT make it PID 1 — the
# init-manager switch is a bench decision; until then systemd boots
# direct and vrxhost runs per its unit.
#
# SPDX-License-Identifier: MIT
#

SUMMARY = "vrxinit: PID 1 — mount the basics, exec systemd, VRX_DEBUG enables a console"
HOMEPAGE = "https://github.com/vipincr/vrx-linux"
SECTION = "core"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://LICENSE;md5=a16ed7a590c33c21c11c7627d9b79efd"

inherit cargo

SRC_URI = "git://github.com/vipincr/vrx-linux.git;protocol=https;branch=master \
           "
SRCREV = "52938873f8c7056532d95d3c5cf0dcdf5b6d15b3"

# the workspace member this recipe builds; the lock is the workspace's
CARGO_SRC_DIR = "rust/init"
CARGO_LOCK_PATH = "${S}/Cargo.lock"

# AFTER the SRC_URI assignment above: the crates manifest appends to
# it, and a require before the assignment would be wiped by the plain
# `=` (bitbake parse order). Generated from Cargo.lock:
#   cargo run -p vrx-xtask -- crates-inc vrx-init layer/recipes-core/vrxinit/vrxinit-crates.inc
require vrxinit-crates.inc

# S is NOT restated: wrynose's bitbake.conf sets it correctly for git
# sources, and a recipe-side S = "${WORKDIR}/git" is a hard error.

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${B}/target/${RUST_TARGET_SYS}/release/vrxinit ${D}${bindir}/
}

FILES:${PN} = "${bindir}/vrxinit"
