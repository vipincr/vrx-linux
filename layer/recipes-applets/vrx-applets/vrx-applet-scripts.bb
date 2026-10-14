SUMMARY = "vrx applet: Scripts (run Python scripts in the applet's folder)"
VRX_APPLET = "scripts"
require vrx-applet.inc

SRC_URI += "file://vrx-script@.service"

# the samples copied into the scripts folder on first open; the vrx
# module a script draws its screen with (plan 0013 D13); the template a
# background script runs as
do_install:append() {
    install -d ${D}${FLUTTER_INSTALL_DIR}/samples ${D}${FLUTTER_INSTALL_DIR}/python
    install -m 0644 ${S}/applets/scripts/samples/*.py ${D}${FLUTTER_INSTALL_DIR}/samples/
    install -m 0644 ${S}/applets/scripts/python/vrx.py ${D}${FLUTTER_INSTALL_DIR}/python/
    install -D -m 0644 ${UNPACKDIR}/vrx-script@.service ${D}${systemd_system_unitdir}/vrx-script@.service
    sed -i -e 's#@VRX_SCRIPTS_PYTHON@#${FLUTTER_INSTALL_DIR}/python#' ${D}${systemd_system_unitdir}/vrx-script@.service
}

FILES:${PN} += "${systemd_system_unitdir}/vrx-script@.service"

RDEPENDS:${PN} += "python3-core python3-json"
