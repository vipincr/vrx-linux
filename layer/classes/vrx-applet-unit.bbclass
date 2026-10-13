# The systemd side of a vrx applet (plan 0008 D1, D2, D14, D16), shared by
# every applet recipe whatever its runtime. From the applet's manifest it
# generates the unit drop-in vrx-applet@<id>.service.d/10-manifest.conf:
#
#   ExecStart  flutter: flutter-vrx --release --app ${VRX_FLUTTER_BUNDLE}
#              dart, rust, native: ${VRX_APPLET_DIR}/app
#   SupplementaryGroups / DeviceAllow
#              the groups and device classes its system grants map to
#              (files/grants.conf, vrx-policy creates the groups); a UI
#              applet also gets video, render and the DRM devices
#
# and creates the applet's own user and group vrx-<id>.
#
# A recipe sets VRX_APPLET (the manifest id) and VRX_APPLET_DIR (where the
# manifest is installed); a flutter applet also VRX_FLUTTER_BUNDLE.

VRX_APPLET ?= ""
VRX_APPLET_DIR ?= "/system/defaults/${VRX_APPLET}"
VRX_FLUTTER_BUNDLE ?= ""
VRX_GRANTS_CONF = "${VRX_LINUX_LAYERDIR}/recipes-applets/vrx-applets/files/grants.conf"

python vrx_applet_unit() {
    import os, tomllib
    applet = d.getVar('VRX_APPLET')
    manifest_path = d.getVar('D') + os.path.join(d.getVar('VRX_APPLET_DIR'), 'manifest.toml')
    with open(manifest_path, 'rb') as f:
        manifest = tomllib.load(f)
    section = manifest.get('applet', {})
    runtime = section.get('runtime')
    grants = section.get('permissions', {}).get('system', [])
    table = vrx_grants_table(d)
    unknown = [g for g in grants if g not in table]
    if unknown:
        bb.fatal("%s: manifest grants %s, which grants.conf does not define" % (applet, unknown))
    groups = set()
    devices = set()
    for grant in grants:
        group, classes = table[grant]
        groups.add(group)
        devices.update(classes)
    if runtime == 'flutter':
        bundle = d.getVar('VRX_FLUTTER_BUNDLE')
        if not bundle:
            bb.fatal("%s: a flutter applet needs VRX_FLUTTER_BUNDLE" % applet)
        exec_start = "/usr/bin/flutter-vrx --release --app %s" % bundle
        # the KMS node its buffers come from and the GPU's render node
        groups.update(['video', 'render'])
        devices.add('char-drm')
    elif runtime in ('dart', 'rust', 'native'):
        exec_start = os.path.join(d.getVar('VRX_APPLET_DIR'), 'app')
    else:
        bb.fatal("%s: unknown runtime %r" % (applet, runtime))
    lines = [
        "# Generated from the %s manifest by vrx-applet-unit.bbclass. Do not edit." % applet,
        "[Service]",
        "ExecStart=%s" % exec_start,
    ]
    if groups:
        lines.append("SupplementaryGroups=%s" % " ".join(sorted(groups)))
    for device in sorted(devices):
        lines.append("DeviceAllow=%s rw" % device)
    dropdir = d.getVar('D') + d.getVar('systemd_system_unitdir') + '/vrx-applet@%s.service.d' % applet
    os.makedirs(dropdir, exist_ok=True)
    with open(os.path.join(dropdir, '10-manifest.conf'), 'w') as f:
        f.write("\n".join(lines) + "\n")
}
do_install[postfuncs] += "vrx_applet_unit"
do_install[file-checksums] += "${VRX_GRANTS_CONF}:True"

def vrx_grants_table(d):
    """grants.conf: grant = group [device class...]"""
    table = {}
    with open(d.getVar('VRX_GRANTS_CONF')) as f:
        for line in f:
            line = line.split('#', 1)[0].strip()
            if not line:
                continue
            key, _, rest = line.partition('=')
            words = rest.split()
            table[key.strip()] = (words[0], words[1:])
    return table

# The applet's own user and group; its home is the unit's StateDirectory.
# No colon in the comment: it is a passwd field.
inherit useradd
USERADD_PACKAGES = "${PN}"
GROUPADD_PARAM:${PN} = "-r vrx-${VRX_APPLET}"
USERADD_PARAM:${PN} = "-r -g vrx-${VRX_APPLET} -d /var/lib/vrx/${VRX_APPLET} -M -s /sbin/nologin -c 'vrx applet ${VRX_APPLET}' vrx-${VRX_APPLET}"

FILES:${PN} += "${systemd_system_unitdir}/vrx-applet@${VRX_APPLET}.service.d"
# vrxhost ships the unit template and the vrx group; vrx-policy the
# groups the grants map to
RDEPENDS:${PN} += "vrxhost vrx-policy"
