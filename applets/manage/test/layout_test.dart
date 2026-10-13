import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_check/vrx_check.dart';

import 'package:manage_applet/main.dart';
import 'package:manage_applet/state.dart';

/// Every Manage screen on every display vrx drives (vrx_check, AGENTS.md
/// rule 11).
void main() {
  ManageModel model({required bool serving, String? error}) => ManageModel()
    ..serving = serving
    ..hostname = 'kitchen-display-in-the-hall'
    ..ips = ['192.168.100.200', '10.10.10.8']
    ..error = error;
  final screens = {
    'stopped': () => model(serving: false),
    'serving': () => model(serving: true, error: 'This applet may not serve the page (the serve grant)'),
  };
  for (final display in allDisplays) {
    for (final s in screens.entries) {
      testWidgets('manage ${s.key} on ${display.name}', (tester) async {
        await expectCleanLayout(tester, ManageApplet(s.value()), display: display);
      });
    }
  }
}
