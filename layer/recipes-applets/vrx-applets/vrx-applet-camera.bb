SUMMARY = "vrx applet: Camera (a viewfinder and photos, a client of camerad)"
VRX_APPLET = "camera"
require vrx-applet.inc

# The picture is a texture the flutter-vrx camera plugin fills, and photos
# are camerad's (vrx-applet-camerad): the applet holds no device grant.
# Both ride together on VRX_CAMERA in packagegroup-vrx-linux's derived
# list (plan 0018 D4b; review 2026-10-17, KRN-07: the applet rides with
# its siblings, not from the UI layer), and it needs camerad running to
# have anything to show.
RDEPENDS:${PN} += "vrx-applet-camerad"
