import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

import 'package:clock_applet/state.dart';

void main() {
  test('the boot action seeds the 24-hour view', () {
    final harness = StoreHarness(ClockModel());
    harness.assertView((v) => v.is24h && v.time == '13:04');
  });

  test('the format change flips the rendering', () {
    final harness = StoreHarness(ClockModel());
    harness.dispatch(ClockAction.formatChanged);
    harness.assertView((v) => !v.is24h && v.time == '1:04 PM');
  });

  test('an alarm puts the clock on the ring screen', () {
    final harness = StoreHarness(ClockModel());
    harness.dispatch(ClockAction.alarmFired);
    harness.assertView((v) => v.ringing);
    harness.dispatch(ClockAction.snoozeTapped);
    harness.assertView((v) => !v.ringing);
  });
}
