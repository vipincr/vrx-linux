import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_check/vrx_check.dart';

import 'package:setup_applet/main.dart';
import 'package:setup_applet/state.dart';

/// Every Setup step holds on every display vrx drives (vrx_check).
void main() {
  for (final display in allDisplays) {
    for (final step in SetupStep.values) {
      testWidgets('setup ${step.name} on ${display.name}', (tester) async {
        final model = SetupModel()
          ..step = step
          ..name = 'Kitchen display'
          ..zone = 'America/Argentina/Buenos_Aires'
          ..zones = ['America/Argentina/Buenos_Aires', 'Asia/Kolkata']
          ..network = 'Wired (10.10.10.8)';
        await expectCleanLayout(tester, SetupApplet(model), display: display);
      });
    }
    testWidgets('setup again, its end, on ${display.name}', (tester) async {
      final model = SetupModel()
        ..again = true
        ..step = SetupStep.done
        ..name = 'Kitchen display'
        ..zone = 'Asia/Kolkata';
      await expectCleanLayout(tester, SetupApplet(model), display: display);
    });
  }
}
