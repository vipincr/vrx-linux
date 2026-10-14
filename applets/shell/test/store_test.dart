import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

import 'package:shell_applet/state.dart';

void main() {
  // the reduce budget times one action; a fresh test isolate compiles the
  // reducer's pattern switch on its first ShellFacts (the device runs AOT,
  // which has no such first call), so warm it once, untimed
  setUpAll(() => ShellModel()
    ..reduce(const ShellState(), const ShellFacts(clockValid: true, depth: 1, notice: Change('x')))
    ..reduce(const ShellState(), ShellAction.back));

  test('the strip shows the system\'s facts; Back above Home; the drawer opens and shuts', () {
    final model = ShellModel(now: () => DateTime(2026, 10, 13, 9, 5).millisecondsSinceEpoch);
    final h = StoreHarness(model);
    h.assertView((v) => v.facts.clockText == '--:--' && !v.canGoBack && !v.drawer,
        because: 'an unset clock reads --:--');
    h.dispatch(const ShellFacts(clockValid: true, wifiUp: true, depth: 1));
    h.assertView((v) => v.facts.clockText == '09:05' && v.wifiUp && !v.canGoBack, because: 'Home alone is depth 1');
    h.assertView((v) => !v.bleUp && !v.facts.bleUp, because: 'the radio is off until connman says on');
    h.dispatch(const ShellFacts(bleUp: true));
    h.assertView((v) => v.bleUp && v.facts.bleUp, because: 'the strip and the drawer both say the radio is on');
    h.assertView((v) => !v.facts.wiredUp, because: 'no wired glyph until connman says a cable is up');
    h.dispatch(const ShellFacts(wiredUp: true));
    h.assertView((v) => v.facts.wiredUp && v.facts.wifiUp, because: 'the wired glyph sits beside Wi-Fi, each its own fact');
    h.dispatch(const ShellFacts(wiredUp: false));
    h.assertView((v) => !v.facts.wiredUp, because: 'the cable out: the glyph goes');
    h.dispatch(const ShellFacts(depth: 2));
    h.assertView((v) => v.canGoBack, because: 'an applet above Home');
    h.assertView((v) => !v.facts.cameraOn, because: 'no camera runs until camerad says so');
    h.dispatch(const ShellFacts(cameraOn: true));
    h.assertView((v) => v.facts.cameraOn, because: 'the strip marks a running camera whoever started it (plan 0018 D11)');
    h.dispatch(const ShellFacts(cameraOn: false));
    h.assertView((v) => !v.facts.cameraOn);
    h.dispatch(ShellAction.drawerOpened);
    h.assertView((v) => v.drawer);
    h.dispatch(ShellAction.drawerOpened);
    h.assertView((v) => v.drawer, because: 'opening an open drawer changes nothing');
    // the power button closes the drawer and asks; the shell keeps the
    // screen until it is answered
    h.dispatch(ShellAction.powerAsked);
    h.assertView((v) => !v.drawer && v.askingPower);
    h.dispatch(ShellAction.powerDismissed);
    h.assertView((v) => !v.drawer && !v.askingPower);
    h.dispatch(ShellAction.drawerOpened);
    h.dispatch(ShellAction.drawerClosed);
    h.assertView((v) => !v.drawer);
    h.dispatch(ShellAction.drawerOpened);
    h.verify(
      fresh: () => ShellModel(now: () => DateTime(2026, 10, 13, 9, 5).millisecondsSinceEpoch),
      probes: const [ShellAction.back, ShellAction.powerAsked, ShellAction.drawerOpened, ShellAction.drawerClosed],
    );
  });

  test('the brightness slider is offered only where the screen dims (plan 0010 D8)', () {
    final model = ShellModel();
    final h = StoreHarness(model);
    h.assertView((v) => v.brightness == null, because: 'the compositor has not said it can dim');
    h.dispatch(const ShellFacts(dimming: VrxDimming.alpha, brightness: 30));
    h.assertView((v) => v.brightness == 30);
  });

  test('the battery is said by zone, and an alarm before a power-off only without a timed wake (plan 0012 D10, D15)', () {
    final model = ShellModel(now: () => DateTime(2026, 10, 13, 22).millisecondsSinceEpoch);
    final h = StoreHarness(model);
    expect(h.view.batteryNotice, isNull, reason: 'no battery, or above its zones');
    h.dispatch(const ShellFacts(batteryZone: 'warn', batteryShown: 14));
    expect(h.view.batteryNotice, 'The battery is low (14 %). The screen is dimmer until it charges.');
    expect(h.view.batteryCritical, isFalse);
    h.dispatch(const ShellFacts(batteryZone: 'critical'));
    expect(h.view.batteryNotice, contains('turns off in 30 seconds'));
    expect(h.view.batteryCritical, isTrue);
    h.dispatch(const ShellFacts(batteryZone: ''));
    expect(h.view.batteryNotice, isNull, reason: 'on a charger the zone clears');
    expect(h.view.powerOffNote, isNull, reason: 'no alarm set');
    h.dispatch(ShellFacts(nextWake: DateTime(2026, 10, 14, 7).millisecondsSinceEpoch ~/ 1000));
    expect(h.view.powerOffNote, 'An alarm is set for 07:00. It will not ring while the device is off.');
    h.dispatch(const ShellFacts(wakeAlarm: true));
    expect(h.view.powerOffNote, isNull, reason: 'an RTC wakes the board for it');
  });

  test('an open power alert is shown until it is answered (plan 0012 D11)', () {
    final model = ShellModel();
    final h = StoreHarness(model);
    h.assertView((v) => v.alert == null, because: 'no alert');
    h.dispatch(const ShellFacts(alerts: [
      PowerAlert(applet: 'web', name: 'Web requests', background: true, percent: 12, answer: 'later'),
      PowerAlert(applet: 'scripts', name: 'Scripts', background: true, percent: 9),
    ]));
    h.assertView((v) => v.alert?.applet == 'scripts', because: 'the first one still waiting for the person');
    h.assertView((v) => v.alert!.sentence == 'Scripts is using a lot of power in the background.',
        because: 'in words, naming it');
    h.dispatch(const ShellFacts(alerts: [PowerAlert(applet: 'scripts', name: 'Scripts', background: true, percent: 9, answer: 'frozen')]));
    h.assertView((v) => v.alert == null, because: 'answered (or frozen): the band goes');
  });
}
