SUMMARY = "vrx applet: Scripts (run Python scripts in the applet's folder)"
VRX_APPLET = "scripts"
require vrx-applet.inc

# the samples copied into the scripts folder on first open
do_install:append() {
    install -d ${D}${FLUTTER_INSTALL_DIR}/samples
    install -m 0644 ${S}/applets/scripts/samples/*.py ${D}${FLUTTER_INSTALL_DIR}/samples/
}

RDEPENDS:${PN} += "python3-core"
