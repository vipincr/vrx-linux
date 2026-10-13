import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_check/vrx_check.dart';

import 'package:clock_applet/main.dart';

import 'screens.dart';

/// Pictures for a person, not a gate (the layout test is):
/// `VRX_SHOTS=1 flutter test --update-goldens test/shots_test.dart`.
void main() {
  for (final display in allDisplays) {
    for (final shot in clockScreens.entries) {
      testWidgets('clock ${shot.key} on ${display.name}', (tester) async {
        await shotApplet(tester, 'clock-${shot.key}', ClockApplet(shot.value()), display: display);
      }, skip: Platform.environment['VRX_SHOTS'] == null);
    }
  }
}
