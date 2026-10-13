import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_check/vrx_check.dart';
import 'package:vrx_kit/vrx_kit.dart';

import 'package:usb_applet/main.dart';
import 'package:usb_applet/state.dart';

/// Every USB screen on every display vrx drives (vrx_check, AGENTS.md
/// rule 11).
void main() {
  UsbModel model(UsbState u, {String? error}) => UsbModel()
    ..usb = u
    ..error = error;
  final screens = {
    'idle': () => model(const UsbState(present: true, connected: false, sharing: false)),
    'connected': () => model(const UsbState(present: true, connected: true, sharing: false)),
    'sharing': () => model(const UsbState(present: true, connected: true, sharing: true),
        error: 'This applet may not share files (the usb grant)'),
  };
  for (final display in allDisplays) {
    for (final s in screens.entries) {
      testWidgets('usb ${s.key} on ${display.name}', (tester) async {
        await expectCleanLayout(tester, UsbApplet(s.value()), display: display);
      });
    }
  }
}
