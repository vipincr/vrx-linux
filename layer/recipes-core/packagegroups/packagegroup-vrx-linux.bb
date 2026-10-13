# The vrx-linux payload: what a vrx image gains when it opts in
# through VRX_APPS (plan 0007 part L).
#
# SPDX-License-Identifier: MIT
#

SUMMARY = "vrx-linux applet OS packages"
DESCRIPTION = "vrxhost (the daemon), vrxinit, and with a UI the built-in \
               applets. The compositor is flutter-vrx (meta-vrx-ui); the \
               SDKs ship to developers, not to the image."
LICENSE = "MIT"

PACKAGE_ARCH = "${MACHINE_ARCH}"

inherit packagegroup

COMPATIBLE_MACHINE = "^vrxboard-"

RDEPENDS:${PN} = "\
    vrxhost \
    vrxinit \
    vrx-policy \
    ${@'vrx-applet-launcher vrx-applet-clock vrx-applet-settings vrx-applet-wifi' if d.getVar('VRX_UI') == 'flutter' else ''} \
"

# The built-in applets render through flutter-vrx, so they ride only on
# an image with the Flutter UI (VRX_UI = "flutter", validated by
# packagegroup-vrx-ui); a headless vrx-linux image is vrxhost alone.
