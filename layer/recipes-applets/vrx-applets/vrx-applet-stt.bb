# vrx applet: Speech to text (plan 0011 D18), the first Rust built-in.
# Resident, no screen: on sys.stt.listen it records through arecord,
# finds the speech, has the local whisper-server (vrx-ml) write it down
# and answers sys.stt.heard. Installed where vrxhost's registry scans
# built-ins, /system/defaults/stt/{manifest.toml,app}; its unit drop-in
# and user come from vrx-applet-unit.bbclass, as every applet's do.
#
# SPDX-License-Identifier: MIT

SUMMARY = "vrx applet: Speech to text (local whisper-server)"
SECTION = "core"
VRX_APPLET = "stt"
require vrx-applet-source.inc

inherit cargo

# a standalone crate (applets/ are never workspace members) whose lock is
# a subset of the workspace's, so the workspace's crates list covers it
CARGO_SRC_DIR = "applets/stt"
CARGO_LOCK_PATH = "${S}/applets/stt/Cargo.lock"
# the standalone applets build outside the workspace: the workspace's
# crates manifest is the bulk, and vrx-applet-crates.inc is the DELTA
# their own locks add on top of it (its header says so)
require recipes-core/vrx-workspace-crates.inc
require recipes-core/vrx-applet-crates.inc

do_install() {
    install -D -m 0755 ${B}/target/${RUST_TARGET_SYS}/release/stt ${D}/system/defaults/stt/app
    install -D -m 0644 ${S}/applets/stt/manifest.toml ${D}/system/defaults/stt/manifest.toml
}

VRX_APPLET_DIR = "/system/defaults/stt"
inherit vrx-applet-unit

FILES:${PN} += "/system/defaults/stt"
# arecord records (ALSA's aplay package carries it); vrx-ml is the whisper-server behind /run/vrx-ml/stt.sock
RDEPENDS:${PN} += "alsa-utils-aplay vrx-ml"
