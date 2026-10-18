# The vrx-linux payload: what a vrx image gains when it opts in
# through VRX_APPS (plan 0007 part L).
#
# SPDX-License-Identifier: MIT
#

SUMMARY = "vrx-linux applet OS packages"
DESCRIPTION = "vrxhost (the daemon) and with a UI the built-in \
               applets. The compositor is flutter-vrx (meta-vrx-ui); the \
               SDKs ship to developers, not to the image."
LICENSE = "MIT"

PACKAGE_ARCH = "${MACHINE_ARCH}"

inherit packagegroup

COMPATIBLE_MACHINE = "^vrxboard-"

RDEPENDS:${PN} = "\
    vrxhost \
    vrx-policy \
    vrx-usb \
    vrx-manage \
    ${@'vrx-theme' if d.getVar('VRX_UI') == 'flutter' else ''} \
    ${@'vrx-applet-launcher vrx-applet-shell vrx-applet-clock vrx-applet-settings vrx-applet-wifi vrx-applet-setup vrx-applet-docs vrx-applet-usbport vrx-applet-devicelink vrx-applet-manage vrx-applet-scripts vrx-applet-web vrx-applet-recorder' if d.getVar('VRX_UI') == 'flutter' else ''} \
    ${@'vrx-applet-terminal' if d.getVar('VRX_UI') == 'flutter' and d.getVar('VRX_DEBUG') == '1' else ''} \
    ${@'vrx-applet-stt' if vrx_ml_role(d, 'speech') else ''} \
    ${@'vrx-applet-assistant' if d.getVar('VRX_UI') == 'flutter' and vrx_ml_role(d, 'chat') else ''} \
    ${@'vrx-matter' if vrx_matter(d) else ''} \
"

# The built-in applets render through flutter-vrx, so they ride only on
# an image with the Flutter UI (VRX_UI = "flutter", validated by
# packagegroup-vrx-ui); a headless vrx-linux image is vrxhost alone.
# Terminal rides only on a debug image as well: its unit lifts the
# sandbox and sudo works in it (vrx-image refuses it in production).
# The local assistant and speech (plan 0011 D18) ride only where their
# model does: a model is an opt-in recipe (meta-vrx, VRX_ML_MODELS, named
# by role: chat-*, speech-*), and its package brings its server units
# (vrx-ml-chat, vrx-ml-speech). An image with no model listed has neither
# applet. stt has no screen; the assistant needs the Flutter UI as well.
def vrx_ml_role(d, role):
    if not bb.utils.contains('VRX_ML', 'packagegroup-vrx-ml', True, False, d):
        return False
    return any(m.startswith(role + '-') for m in (d.getVar('VRX_ML_MODELS') or '').split())

# Matter (plan 0015 D13): opt-in, VRX_MATTER = "1" (meta-vrx's layer.conf
# defaults it empty). A test-attested device advertising itself on every
# network it joins is not a default.
def vrx_matter(d):
    v = (d.getVar('VRX_MATTER') or '').strip()
    if v not in ('1', ''):
        bb.fatal("VRX_MATTER must be '1' (the device on a Matter fabric) or '' (none), got '%s'" % v)
    return v == '1'
