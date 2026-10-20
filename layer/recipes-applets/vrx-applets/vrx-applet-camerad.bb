# vrx applet: Camera service (plan 0018 D1). Resident, no screen: the one
# process that links libcamera. Built only into an image that asks for a
# camera (packagegroup-vrx-camera, VRX_CAMERA in meta-vrx); a build with
# VRX_CAMERA empty never has it (G055).
#
# The libcamera binding is the `libcamera` cargo feature. Its sys crate runs
# bindgen at build time, so the build host needs libclang and the headers of
# the target libcamera (BINDGEN_EXTRA_CLANG_ARGS points at the sysroot); the
# named fallback if that cannot be made to work in the container is the small
# C++ shim behind the same Source trait (plan 0018 D3).
#
# SPDX-License-Identifier: MIT

SUMMARY = "vrx applet: Camera service (libcamera, JPEG stills, the viewfinder queue)"
SECTION = "core"
VRX_APPLET = "camerad"
require vrx-applet-source.inc

inherit cargo pkgconfig

CARGO_SRC_DIR = "applets/camerad"
CARGO_LOCK_PATH = "${S}/applets/camerad/Cargo.lock"
CARGO_BUILD_FLAGS += "--features libcamera"
require recipes-core/vrx-applet-crates.inc
# the registry crates only camerad's lock has (cargo xtask crates-inc)
require recipes-core/vrx-applet-crates.inc

DEPENDS += "libcamera libjpeg-turbo"
export BINDGEN_EXTRA_CLANG_ARGS = "--sysroot=${STAGING_DIR_TARGET}"

do_install() {
    install -D -m 0755 ${B}/target/${RUST_TARGET_SYS}/release/camerad ${D}/system/defaults/camerad/app
    install -D -m 0644 ${S}/applets/camerad/manifest.toml ${D}/system/defaults/camerad/manifest.toml
    # the photo folder (plan 0018 D15, owner: /data/photos): camerad writes it,
    # the photos grant's group reads it, setgid keeps the group on new files
    install -D -m 0644 ${UNPACKDIR}/camerad-tmpfiles.conf ${D}${nonarch_libdir}/tmpfiles.d/camerad.conf
    # the runtime directory, as a second drop-in beside the manifest's
    install -D -m 0644 ${UNPACKDIR}/camerad-runtime.conf ${D}${systemd_system_unitdir}/vrx-applet@camerad.service.d/20-runtime.conf
}

SRC_URI += "file://camerad-tmpfiles.conf file://camerad-runtime.conf"

VRX_APPLET_DIR = "/system/defaults/camerad"
inherit vrx-applet-unit

FILES:${PN} += "/system/defaults/camerad ${nonarch_libdir}/tmpfiles.d/camerad.conf"
# the unit's RuntimeDirectory (state.json) comes from the manifest's unit
# generator; libcamera's IPA modules run as child processes under the sandbox
RDEPENDS:${PN} += "libcamera libjpeg-turbo"
