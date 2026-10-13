SUMMARY = "vrx applet: Assistant (chat with the local model; speak a question)"
VRX_APPLET = "assistant"
require vrx-applet.inc
# the model servers behind /run/vrx-ml (llama-server, whisper-server)
RDEPENDS:${PN} += "vrx-ml"
