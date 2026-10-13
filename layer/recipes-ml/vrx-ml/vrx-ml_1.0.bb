# The local model servers' units and their models list (plan 0011 D18):
# llama-server (chat) and whisper-server (speech), each behind a unix
# socket only the ml grant's group reaches, started by its first
# connection through systemd-socket-proxyd and stopped two minutes after
# its last; and the fetch a person agrees to, by path activation, against
# the pinned SHA-256s in models.toml. The engines are meta-vrx's
# llama-cpp and whisper-cpp (packagegroup-vrx-ml); this recipe ships
# where VRX_ML carries that packagegroup (vrx-linux's packagegroup).
#
# SPDX-License-Identifier: MIT

SUMMARY = "vrx local models: the servers' sockets and units, and the fetch"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://vrx-llm.socket file://vrx-llm-proxy.service file://vrx-llm-server.service \
           file://vrx-stt.socket file://vrx-stt-proxy.service file://vrx-stt-server.service \
           file://vrx-ml-fetch.path file://vrx-ml-fetch.service \
           file://vrx-ml-fetch file://vrx-ml-ready file://vrx-ml.conf file://models.toml"
S = "${UNPACKDIR}"

inherit allarch systemd

do_configure[noexec] = "1"
do_compile[noexec] = "1"
do_install() {
    for u in vrx-llm.socket vrx-llm-proxy.service vrx-llm-server.service \
             vrx-stt.socket vrx-stt-proxy.service vrx-stt-server.service \
             vrx-ml-fetch.path vrx-ml-fetch.service; do
        install -D -m 0644 ${UNPACKDIR}/$u ${D}${systemd_system_unitdir}/$u
    done
    install -D -m 0755 ${UNPACKDIR}/vrx-ml-fetch ${D}${libexecdir}/vrx/vrx-ml-fetch
    install -D -m 0755 ${UNPACKDIR}/vrx-ml-ready ${D}${libexecdir}/vrx/vrx-ml-ready
    install -D -m 0644 ${UNPACKDIR}/vrx-ml.conf ${D}${nonarch_libdir}/tmpfiles.d/vrx-ml.conf
    install -D -m 0644 ${UNPACKDIR}/models.toml ${D}${datadir}/vrx-ml/models.toml
}

FILES:${PN} = "${systemd_system_unitdir} ${libexecdir}/vrx ${nonarch_libdir}/tmpfiles.d/vrx-ml.conf ${datadir}/vrx-ml"

# the sockets and the fetch path listen from boot; the servers and the
# proxies start only through them
SYSTEMD_SERVICE:${PN} = "vrx-llm.socket vrx-stt.socket vrx-ml-fetch.path"
SYSTEMD_AUTO_ENABLE = "enable"

# the engines (meta-vrx), the fetch's tools, systemd-socket-proxyd (in
# systemd's extra-utils), and the vrx-ml group (vrx-policy makes every
# grant group)
RDEPENDS:${PN} = "llama-cpp whisper-cpp curl systemd-extra-utils vrx-policy"
