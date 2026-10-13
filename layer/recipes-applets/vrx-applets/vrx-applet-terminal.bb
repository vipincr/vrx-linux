SUMMARY = "vrx applet: Terminal (zsh on a pty; debug images only)"
VRX_APPLET = "terminal"
require vrx-applet.inc

# The bench's shell on the device: the unit's sandbox lifts and
# vrx-terminal may sudo. packagegroup-vrx-linux installs this only with
# VRX_DEBUG=1, and vrx-image fails a production build that carries it.
SRC_URI += "file://terminal-debug.conf file://vrx-terminal.sudoers"

do_install:append() {
    install -D -m 0644 ${UNPACKDIR}/terminal-debug.conf \
        ${D}${systemd_system_unitdir}/vrx-applet@terminal.service.d/20-debug.conf
    install -D -m 0440 ${UNPACKDIR}/vrx-terminal.sudoers ${D}${sysconfdir}/sudoers.d/vrx-terminal
}

FILES:${PN} += "${sysconfdir}/sudoers.d/vrx-terminal"
# zsh on the pty; setsid -c (busybox) makes the pty its controlling
# terminal; the xterm-256color entry; the face the terminal draws in
RDEPENDS:${PN} += "zsh sudo busybox ncurses-terminfo-base liberation-fonts"
