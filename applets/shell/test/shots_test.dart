import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_check/vrx_check.dart';
import 'package:vrx_kit/vrx_kit.dart';

import 'package:shell_applet/main.dart';
import 'package:shell_applet/state.dart';

/// Pictures for a person: `VRX_SHOTS=1 flutter test --update-goldens test/shots_test.dart`.
void main() {
  ShellModel model({bool drawer = false}) =>
      ShellModel(now: () => DateTime(2026, 10, 13, 23, 59).millisecondsSinceEpoch)
        ..clockValid = true
        ..wifiUp = true
        ..depth = 2
        ..version = 'vrx 0.1.0077'
        ..dimming = VrxDimming.alpha
        ..brightness = 60
        ..drawer = drawer;
  for (final display in [disp28a, hdmi1080]) {
    // one mount a test: a second AppletHost in the same test keeps the
    // first one's store
    testWidgets('shell strip on ${display.name}', (tester) async {
      await shotApplet(tester, 'shell-strip', ShellApplet(model()), display: display);
    }, skip: Platform.environment['VRX_SHOTS'] == null);
    testWidgets('shell drawer on ${display.name}', (tester) async {
      await shotApplet(tester, 'shell-drawer', ShellApplet(model(drawer: true)), display: display);
    }, skip: Platform.environment['VRX_SHOTS'] == null);
  }
}
