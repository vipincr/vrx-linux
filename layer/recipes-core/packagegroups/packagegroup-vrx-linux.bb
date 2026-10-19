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

# The applet list is DERIVED from the recipe files (review 2026-10-17,
# CHG-01, CON-05): every vrx-applet-<id>.bb under recipes-applets ships
# wherever its ride below says, so a new applet is its directory, its
# manifest and one recipe file, with no packagegroup edit. Only the rides
# that differ from "with the Flutter UI" are spelled here; an id missing
# from RIDES rides with the UI.
#
#   ui       the default: VRX_UI = "flutter"
#   debug    the UI and a debug image (VRX_DEBUG = "1")
#   camera   VRX_CAMERA (the product knob; the Camera applet rides with
#            camerad, its service, not from the UI layer)
#   ml:role  the UI and a model of that role in VRX_ML_MODELS
#   None     never in an image (a bench tool)
VRX_APPLET_RIDES = "\
    camera=camera \
    camerad=camera \
    terminal=debug \
    stt=ml:speech \
    assistant=ml:chat \
    console=None \
"

RDEPENDS:${PN} = "\
    vrxhost \
    vrx-policy \
    vrx-usb \
    vrx-manage \
    ${@'vrx-theme' if d.getVar('VRX_UI') == 'flutter' else ''} \
    ${@vrx_applet_packages(d)} \
    ${@'vrx-matter' if vrx_matter(d) else ''} \
"
# vrx_applet_packages reads the recipes directory at parse: the flag
# hashes the expanded list, so an applet recipe added or removed changes
# the packagegroup's hash (R16's rule; without it the call text is hashed
# and a new applet would not move the image).
RDEPENDS:${PN}[vardepvalue] = "${RDEPENDS:${PN}}"

def vrx_applet_packages(d):
    import os, glob
    ui = d.getVar('VRX_UI') == 'flutter'
    debug = d.getVar('VRX_DEBUG') == '1'
    camera = bool((d.getVar('VRX_CAMERA') or '').strip())
    rides = vrx_applet_rides(d)
    here = os.path.dirname(d.getVar('FILE'))
    pattern = os.path.join(here, '..', '..', 'recipes-applets', 'vrx-applets',
                           'vrx-applet-*.bb')
    pkgs = []
    for recipe in sorted(glob.glob(pattern)):
        applet = os.path.basename(recipe)[len('vrx-applet-'):-len('.bb')]
        ride = rides.get(applet, 'ui')
        if ride == 'None':
            continue
        if ride in ('ui', 'debug', 'ml:chat') and not ui:
            continue
        if ride == 'debug' and not debug:
            continue
        if ride == 'camera' and not camera:
            continue
        if ride == 'ml:speech' and not (ui and vrx_ml_role(d, 'speech')):
            continue
        if ride == 'ml:chat' and not vrx_ml_role(d, 'chat'):
            continue
        pkgs.append('vrx-applet-' + applet)
    return ' '.join(pkgs)

def vrx_applet_rides(d):
    rides = {}
    for pair in (d.getVar('VRX_APPLET_RIDES') or '').split():
        applet, _, ride = pair.partition('=')
        rides[applet] = ride
    return rides

# The static account table (plan 0021, G073) names every applet user the
# layer makes; a derived applet with no row would fail the image at
# useradd, late. Refused here, at parse, naming the missing row.
python () {
    import os, glob, re
    here = os.path.dirname(d.getVar('FILE'))
    layer = os.path.join(here, '..', '..', '..')
    passwd = os.path.join(layer, 'files', 'vrx-linux-passwd')
    if os.path.exists(passwd):
        have = set(re.findall(r'^(vrx-[\w-]+):', open(passwd).read(), re.M))
        rides = vrx_applet_rides(d)
        for recipe in sorted(glob.glob(os.path.join(here, '..', '..',
                'recipes-applets', 'vrx-applets', 'vrx-applet-*.bb'))):
            applet = os.path.basename(recipe)[len('vrx-applet-'):-len('.bb')]
            if ('vrx-' + applet) not in have:
                bb.fatal("layer/files/vrx-linux-passwd has no row for vrx-%s: "
                         "plan 0021's table is the applet list's account half; "
                         "add the row (the lint prints the next free number)"
                         % applet)
}

# The built-in applets render through flutter-vrx, so they ride only on
# an image with the Flutter UI (VRX_UI = "flutter", validated by
# packagegroup-vrx-ui). Terminal rides only on a debug image as well: its
# unit lifts the sandbox and sudo works in it (vrx-image refuses it in
# production). Camera and camerad ride on VRX_CAMERA together: the applet
# is a client of the service (plan 0018 D4b). The local assistant and
# speech (plan 0011 D18) ride only where their model does: a model is an
# opt-in recipe (meta-vrx, VRX_ML_MODELS, named by role: chat- *,
# speech-*), and its package brings its server units (vrx-ml-chat,
# vrx-ml-speech). An image with no model listed has neither applet.
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
