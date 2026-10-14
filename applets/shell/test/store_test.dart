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
    h.assertView((v) => v.facts.clockText == '09:05' && v.wifiUp && !v.canGoBack, because: 'Home alone is depth 1');
    h.assertView((v) => !v.bleUp && !v.facts.bleUp, because: 'the radio is off until connman says on');
    model.bleUp = true;
    h.dispatch(ShellAction.factsChanged);
    h.assertView((v) => v.bleUp && v.facts.bleUp, because: 'the strip and the drawer both say the radio is on');
    model.depth = 2;
    h.dispatch(ShellAction.factsChanged);
    h.assertView((v) => v.canGoBack, because: 'an applet above Home');
    h.dispatch(ShellAction.drawerToggled);
    h.assertView((v) => v.drawer);
    // the power button closes the drawer and asks; the shell keeps the
    // screen until it is answered
    h.dispatch(ShellAction.powerAsked);
    h.assertView((v) => !v.drawer && v.askingPower);
    h.dispatch(ShellAction.powerDismissed);
    h.assertView((v) => !v.drawer && !v.askingPower);
  });

  test('the brightness slider is offered only where the screen dims (plan 0010 D8)', () {
    final model = ShellModel();
    final h = StoreHarness(model);
    h.assertView((v) => v.brightness == null, because: 'the compositor has not said it can dim');
    model
      ..dimming = VrxDimming.alpha
      ..brightness = 30;
    h.dispatch(ShellAction.factsChanged);
    h.assertView((v) => v.brightness == 30);
  });

  test('an open power alert is shown until it is answered (plan 0012 D11)', () {
    final model = ShellModel();
    final h = StoreHarness(model);
    h.assertView((v) => v.alert == null, because: 'no alert');
    model.alerts = const [
      PowerAlert(applet: 'web', name: 'Web requests', background: true, percent: 12, answer: 'later'),
      PowerAlert(applet: 'scripts', name: 'Scripts', background: true, percent: 9),
    ];
    h.dispatch(ShellAction.factsChanged);
    h.assertView((v) => v.alert?.applet == 'scripts', because: 'the first one still waiting for the person');
    h.assertView((v) => v.alert!.sentence == 'Scripts is using a lot of power in the background.',
        because: 'in words, naming it');
    model.alerts = const [PowerAlert(applet: 'scripts', name: 'Scripts', background: true, percent: 9, answer: 'frozen')];
    h.dispatch(ShellAction.factsChanged);
    h.assertView((v) => v.alert == null, because: 'answered (or frozen): the band goes');
  });
}
