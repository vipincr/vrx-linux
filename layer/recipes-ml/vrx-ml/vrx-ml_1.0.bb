# The local model servers' units (plan 0011 D18): llama-server (chat)
# and whisper-server (speech), each behind a unix socket only the ml
# grant's group reaches, started by its first connection through
# systemd-socket-proxyd and stopped two minutes after its last.
#
# No model is here and none is downloaded on the device. Each model is
# its own recipe in meta-vrx (recipes-ml/models), fetched by bitbake with
# a pinned SHA-256 and its licence in the image manifest, and installed
# only where a build lists it in VRX_ML_MODELS (the owner, 2026-10-14: the
# model is a separate opt-in recipe). A model's package pulls in its role's
# package here: vrx-ml-chat for a chat model, vrx-ml-speech for a speech
# model. Each serves the link its model installs (/usr/share/vrx-ml/
# chat.gguf, speech.bin).
#
# SPDX-License-Identifier: MIT

SUMMARY = "vrx local models: the servers' sockets and units"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://vrx-llm.socket file://vrx-llm-proxy.service file://vrx-llm-server.service \
           file://vrx-stt.socket file://vrx-stt-proxy.service file://vrx-stt-server.service \
           file://vrx-ml-ready file://vrx-ml-speed file://vrx-ml-speed.service"
S = "${UNPACKDIR}"

inherit allarch systemd

do_configure[noexec] = "1"
do_compile[noexec] = "1"
do_install() {
    for u in vrx-llm.socket vrx-llm-proxy.service vrx-llm-server.service \
             vrx-stt.socket vrx-stt-proxy.service vrx-stt-server.service; do
        install -D -m 0644 ${UNPACKDIR}/$u ${D}${systemd_system_unitdir}/$u
    done
    install -D -m 0755 ${UNPACKDIR}/vrx-ml-ready ${D}${libexecdir}/vrx/vrx-ml-ready
    install -D -m 0755 ${UNPACKDIR}/vrx-ml-speed ${D}${libexecdir}/vrx/vrx-ml-speed
    install -D -m 0644 ${UNPACKDIR}/vrx-ml-speed.service ${D}${systemd_system_unitdir}/vrx-ml-speed.service
}

PACKAGES = "${PN}-chat ${PN}-speech ${PN}"
# the speed hold is shared by both roles (plan 0012 D1)
FILES:${PN} = "${libexecdir}/vrx/vrx-ml-ready ${libexecdir}/vrx/vrx-ml-speed \
               ${systemd_system_unitdir}/vrx-ml-speed.service"
FILES:${PN}-chat = "${systemd_system_unitdir}/vrx-llm.socket ${systemd_system_unitdir}/vrx-llm-proxy.service \
                    ${systemd_system_unitdir}/vrx-llm-server.service"
FILES:${PN}-speech = "${systemd_system_unitdir}/vrx-stt.socket ${systemd_system_unitdir}/vrx-stt-proxy.service \
                      ${systemd_system_unitdir}/vrx-stt-server.service"

# the sockets listen from boot; the servers and the proxies start only
# through them
SYSTEMD_PACKAGES = "${PN}-chat ${PN}-speech"
SYSTEMD_SERVICE:${PN}-chat = "vrx-llm.socket"
SYSTEMD_SERVICE:${PN}-speech = "vrx-stt.socket"
SYSTEMD_AUTO_ENABLE = "enable"

# vrx-ml-ready waits with curl; the proxies are systemd-socket-proxyd (in
# systemd's extra-utils); the vrx-ml group comes from vrx-policy (it makes
# every grant group); each role brings its engine (meta-vrx)
RDEPENDS:${PN} = "curl"
RDEPENDS:${PN}-chat = "${PN} llama-cpp systemd-extra-utils vrx-policy"
RDEPENDS:${PN}-speech = "${PN} whisper-cpp systemd-extra-utils vrx-policy"
