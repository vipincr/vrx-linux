import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_check/vrx_check.dart';

import 'package:terminal_applet/main.dart';
import 'package:terminal_applet/state.dart';

/// The Terminal holds on every display vrx drives (vrx_check): its
/// keyboard is the sanctioned 6mm one, nothing else may be small.
void main() {
  for (final display in allDisplays) {
    for (final keyboard in [true, false]) {
      testWidgets('terminal keyboard=$keyboard on ${display.name}', (tester) async {
        final model = TerminalModel()..keyboard = keyboard;
        await expectCleanLayout(tester, TerminalApplet(model)..wire(), display: display);
      });
    }
  }
}
