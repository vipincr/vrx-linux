SUMMARY = "vrx applet: Recorder (record where there is a microphone, play back)"
VRX_APPLET = "recorder"
require vrx-applet.inc

# ALSA's aplay and arecord (one package)
RDEPENDS:${PN} += "alsa-utils-aplay"
