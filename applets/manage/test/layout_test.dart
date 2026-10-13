import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_check/vrx_check.dart';

import 'package:manage_applet/main.dart';
import 'package:manage_applet/state.dart';

/// Every Manage screen on every display vrx drives (vrx_check, AGENTS.md
/// rule 11).
void main() {
  ManageModel model({required bool serving, String? error, List<String> ips = const ['192.168.100.200', '10.10.10.8']}) => ManageModel()
    ..serving = serving
    ..hostname = 'kitchen-display-in-the-hall'
    ..ips = ips
    ..error = error;
  final screens = {
    'stopped': () => model(serving: false),
    'stopped by itself': () => model(serving: false)..stoppedIdle = true,
    'serving': () => model(serving: true, error: 'This applet is not allowed to do that.'),
    'no network': () => model(serving: true, ips: const []),
    'hosting': () => model(serving: true, ips: const [])
      ..hosting = true
      ..ssid = 'vrx-kitchen-display-in-the-hall'
      ..passphrase = 'abcd2345efgh'
      ..hostedAddress = '192.168.0.1',
  };
  for (final display in allDisplays) {
    for (final s in screens.entries) {
      testWidgets('manage ${s.key} on ${display.name}', (tester) async {
        await expectCleanLayout(tester, ManageApplet(s.value()), display: display);
      });
    }
  }
}
