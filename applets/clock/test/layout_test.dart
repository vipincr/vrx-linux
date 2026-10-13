import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_check/vrx_check.dart';

import 'package:clock_applet/main.dart';

import 'screens.dart';

/// Every Clock screen holds on every display vrx drives: no overlap, no
/// broken word, no control under 9mm or closer than 1mm to another,
/// nothing off the screen (vrx_check).
void main() {
  for (final display in allDisplays) {
    for (final screen in clockScreens.entries) {
      testWidgets('clock ${screen.key} on ${display.name}', (tester) async {
        await expectCleanLayout(tester, ClockApplet(screen.value()), display: display);
      });
    }
  }
}
