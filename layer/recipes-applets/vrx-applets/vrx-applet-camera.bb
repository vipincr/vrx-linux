SUMMARY = "vrx applet: Camera (a viewfinder and photos, a client of camerad)"
VRX_APPLET = "camera"
require vrx-applet.inc

# The picture is a texture the flutter-vrx camera plugin fills, and photos
# are camerad's (vrx-applet-camerad): the applet holds no device grant. It
# is pulled by packagegroup-vrx-ui only where both VRX_UI and VRX_CAMERA
# are set (plan 0018 D4b), and needs camerad running to have anything to
# show.
RDEPENDS:${PN} += "vrx-applet-camerad"
