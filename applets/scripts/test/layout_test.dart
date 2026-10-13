import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_check/vrx_check.dart';

import 'package:scripts_applet/main.dart';
import 'package:scripts_applet/state.dart';

/// The Scripts screens hold on every display vrx drives (vrx_check).
void main() {
  for (final display in allDisplays) {
    testWidgets('scripts list on ${display.name}', (tester) async {
      final model = ScriptsModel()..scripts = ['hello.py', 'system.py', 'a_script_with_a_rather_long_name.py'];
      await expectCleanLayout(tester, ScriptsApplet(model), display: display);
    });
    testWidgets('scripts console on ${display.name}', (tester) async {
      final model = ScriptsModel()
        ..start('system.py')
        ..add('PRETTY_NAME="vrx 0.1.0076"\nRaspberry Pi Compute Module 4 Rev 1.1\nMemTotal:        1887884 kB\nload [\'0.06\', \'0.08\', \'0.03\']\n');
      await expectCleanLayout(tester, ScriptsApplet(model), display: display);
    });
  }
}
