import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

import 'package:shell_applet/state.dart';

void main() {
  test('the strip shows the system\'s facts; Back above Home; the drawer toggles', () {
    final model = ShellModel(now: () => DateTime(2026, 10, 13, 9, 5).millisecondsSinceEpoch);
    final h = StoreHarness(model);
    h.assertView((v) => v.facts.clockText == '--:--' && !v.canGoBack && !v.drawer,
        because: 'an unset clock reads --:--');
    model
      ..clockValid = true
      ..wifiUp = true
      ..depth = 1;
    h.dispatch(ShellAction.factsChanged);
    h.assertView((v) => v.facts.clockText == '09:05' && v.wifiUp && v.canGoBack);
    h.dispatch(ShellAction.drawerToggled);
    h.assertView((v) => v.drawer);
  });
}
