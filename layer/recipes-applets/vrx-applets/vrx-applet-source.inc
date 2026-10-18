# The source every built-in applet builds from, whatever its runtime: the
# Flutter applets (vrx-applet.inc) and the Rust ones (vrx-applet-stt.bb).
# The repository itself is named once for every recipe, in
# recipes-core/vrx-linux-source.inc (KRN-04, review 2026-10-17); this file
# adds only what an applet build differs in.
#
# SPDX-License-Identifier: MIT

require recipes-core/vrx-linux-source.inc

# Every built-in applet builds from the layer's one commit (they share a
# checkout: applets/ plus flutter/vrx_kit and rust/sdk), conf/layer.conf.
PV = "1.0+git${SRCPV}"

COMPATIBLE_MACHINE = "^vrxboard-"
