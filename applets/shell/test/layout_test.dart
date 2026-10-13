import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_check/vrx_check.dart';

import 'package:shell_applet/main.dart';
import 'package:shell_applet/state.dart';

/// The strip and the drawer on every display vrx drives (vrx_check).
void main() {
  ShellModel model({bool drawer = false}) =>
      ShellModel(now: () => DateTime(2026, 10, 13, 23, 59).millisecondsSinceEpoch)
        ..clockValid = true
        ..wifiUp = true
        ..depth = 2
        ..version = 'vrx 0.1.0077'
        ..drawer = drawer;
  for (final display in allDisplays) {
    testWidgets('shell strip on ${display.name}', (tester) async {
      await expectCleanLayout(tester, ShellApplet(model()), display: display);
    });
    testWidgets('shell drawer on ${display.name}', (tester) async {
      await expectCleanLayout(tester, ShellApplet(model(drawer: true)), display: display);
    });
  }
}
