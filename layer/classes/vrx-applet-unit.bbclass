# The systemd side of a vrx applet (plan 0008 D1, D2, D14, D16), shared by
# every applet recipe whatever its runtime. From the applet's manifest,
# `vrx unit` (vrx-cli-native; vrx_protocol::unit, plan 0011 D17, the
# generator vrxhost runs when it installs an applet) writes the unit
# drop-in vrx-applet@<id>.service.d/10-manifest.conf:
#
#   ExecStart  flutter: flutter-vrx --release --app ${VRX_FLUTTER_BUNDLE}
#              dart, rust, native: ${VRX_APPLET_DIR}/app
#   SupplementaryGroups / DeviceAllow
#              the groups and device classes its system grants map to
#              (files/grants.conf, vrx-policy creates the groups); a UI
#              applet also gets video, render and the DRM devices
#
# and the settings defaults /etc/vrx/settings/<id>.conf. This class keeps
# what is the build's alone: the AOT checks and the applet's own user and
# group vrx-<id>.
#
# A recipe sets VRX_APPLET (the manifest id) and VRX_APPLET_DIR (where the
# manifest is installed); a flutter applet also VRX_FLUTTER_BUNDLE.

VRX_APPLET ?= ""
VRX_APPLET_DIR ?= "/system/defaults/${VRX_APPLET}"
VRX_FLUTTER_BUNDLE ?= ""
# Plan 0008 D18's hard budgets: start to usable, and event-loop liveness
# (60 s since plan 0012 D4: a ping is a wake; vrx_protocol::unit's default)
VRX_APPLET_START_BUDGET ?= "5s"
VRX_APPLET_WATCHDOG ?= "60s"
VRX_GRANTS_CONF = "${VRX_LINUX_LAYERDIR}/recipes-applets/vrx-applets/files/grants.conf"

python vrx_applet_unit() {
    import os, subprocess, tomllib
    applet = d.getVar('VRX_APPLET')
    manifest_path = d.getVar('D') + os.path.join(d.getVar('VRX_APPLET_DIR'), 'manifest.toml')
    with open(manifest_path, 'rb') as f:
        runtime = tomllib.load(f).get('applet', {}).get('runtime')
    bundle = d.getVar('VRX_FLUTTER_BUNDLE')
    if runtime == 'flutter':
        if not bundle:
            bb.fatal("%s: a flutter applet needs VRX_FLUTTER_BUNDLE" % applet)
        # D18: only an AOT release bundle ships. A debug or JIT bundle
        # (no libapp.so, or a kernel snapshot in kernel_blob.bin) is slow
        # by construction. meta-flutter leaves an EMPTY kernel_blob.bin
        # in a release bundle; a non-empty one is the JIT kernel.
        root = d.getVar('D') + bundle
        if not os.path.isfile(os.path.join(root, 'lib', 'libapp.so')):
            bb.fatal("%s: %s has no lib/libapp.so: not an AOT release bundle" % (applet, bundle))
        blob = os.path.join(root, 'data', 'flutter_assets', 'kernel_blob.bin')
        if os.path.exists(blob) and os.path.getsize(blob) > 0:
            bb.fatal("%s: %s carries a %d-byte kernel_blob.bin: a JIT bundle, never shipped"
                     % (applet, bundle, os.path.getsize(blob)))
    # the drop-in and the settings defaults: vrx_protocol::unit through
    # `vrx unit` (plan 0011 D17), the generator vrxhost runs at install
    dropin = d.getVar('D') + d.getVar('systemd_system_unitdir') + \
        '/vrx-applet@%s.service.d/10-manifest.conf' % applet
    settings = d.getVar('D') + d.getVar('sysconfdir') + '/vrx/settings/%s.conf' % applet
    cmd = ['vrx', 'unit',
           '--manifest', manifest_path,
           '--dir', d.getVar('VRX_APPLET_DIR'),
           '--grants', d.getVar('VRX_GRANTS_CONF'),
           '--start-budget', d.getVar('VRX_APPLET_START_BUDGET'),
           '--watchdog', d.getVar('VRX_APPLET_WATCHDOG'),
           '--dropin', dropin,
           '--settings', settings]
    if runtime == 'flutter':
        cmd += ['--bundle', bundle]
    done = subprocess.run(cmd, capture_output=True, text=True)
    if done.returncode != 0:
        bb.fatal("%s: vrx unit: %s" % (applet, done.stderr.strip()))
}
do_install[postfuncs] += "vrx_applet_unit"
do_install[file-checksums] += "${VRX_GRANTS_CONF}:True"
# `vrx unit` runs from the native sysroot
DEPENDS += "vrx-cli-native"

# The applet's own user and group; its home is the unit's StateDirectory.
# No colon in the comment: it is a passwd field.
inherit useradd
USERADD_PACKAGES = "${PN}"
GROUPADD_PARAM:${PN} = "-r vrx-${VRX_APPLET}"
USERADD_PARAM:${PN} = "-r -g vrx-${VRX_APPLET} -d /var/lib/vrx/${VRX_APPLET} -M -s /sbin/nologin -c 'vrx applet ${VRX_APPLET}' vrx-${VRX_APPLET}"

FILES:${PN} += "${systemd_system_unitdir}/vrx-applet@${VRX_APPLET}.service.d ${sysconfdir}/vrx/settings"
# a settings default the device has changed is kept across an update
CONFFILES:${PN} += "${sysconfdir}/vrx/settings/${VRX_APPLET}.conf"
# vrxhost ships the unit template and the vrx group; vrx-policy the
# groups the grants map to
RDEPENDS:${PN} += "vrxhost vrx-policy"
