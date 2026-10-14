import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_check/vrx_check.dart';
import 'package:vrx_kit/vrx_kit.dart';

import 'package:shell_applet/main.dart';
import 'package:shell_applet/state.dart';

/// The strip and the drawer on every display vrx drives (vrx_check).
void main() {
  ShellModel model({bool drawer = false, bool power = false}) =>
      ShellModel(now: () => DateTime(2026, 10, 13, 23, 59).millisecondsSinceEpoch)
        ..clockValid = true
        ..wifiUp = true
        ..bleUp = true
        ..trailDepth = 2
        ..version = 'vrx 0.1.0077'
        ..dimming = VrxDimming.alpha
        ..brightness = 60
        ..drawer = drawer
        ..askingPower = power;
  for (final display in allDisplays) {
    testWidgets('shell strip on ${display.name}', (tester) async {
      await expectCleanLayout(tester, ShellApplet(model()), display: display);
    });
    testWidgets('shell drawer on ${display.name}', (tester) async {
      await expectCleanLayout(tester, ShellApplet(model(drawer: true)), display: display);
    });
    testWidgets('shell power question on ${display.name}', (tester) async {
      await expectCleanLayout(tester, ShellApplet(model(power: true)), display: display);
    });
    // an applet over its power budget (plan 0012 D11): the longest name
    // a built-in has, behind the screen
    // the battery's zones (plan 0012 D10) and an alarm that cannot ring
    // through a power-off (D15)
    testWidgets('shell battery low on ${display.name}', (tester) async {
      final m = model()
        ..batteryZone = 'warn'
        ..batteryShown = 15;
      await expectCleanLayout(tester, ShellApplet(m), display: display);
    });
    testWidgets('shell battery critical on ${display.name}', (tester) async {
      final m = model()
        ..batteryZone = 'critical'
        ..batteryShown = 5;
      await expectCleanLayout(tester, ShellApplet(m), display: display);
    });
    testWidgets('shell power question with an alarm set on ${display.name}', (tester) async {
      final m = model(power: true)..nextWake = DateTime(2026, 10, 14, 7).millisecondsSinceEpoch ~/ 1000;
      await expectCleanLayout(tester, ShellApplet(m), display: display);
    });
    // a camera running (plan 0018 D11): the mark joins the strip's glyphs,
    // with the day, the battery and Bluetooth all showing
    testWidgets('shell strip with the camera on on ${display.name}', (tester) async {
      final m = model()
        ..cameraOn = true
        ..battery = const Battery(name: 'BAT0', percent: 100, charging: true);
      await expectCleanLayout(tester, ShellApplet(m), display: display);
    });
    testWidgets('shell power alert on ${display.name}', (tester) async {
      final m = model()
        ..alerts = const [PowerAlert(applet: 'web', name: 'Web requests', background: true, percent: 41.5)];
      await expectCleanLayout(tester, ShellApplet(m), display: display);
    });
  }
}
