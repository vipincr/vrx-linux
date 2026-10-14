import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

import 'package:setup_applet/state.dart';

void main() {
  test('the walk moves one step at a time, in evrx-rt order', () {
    final model = SetupModel();
    final harness = StoreHarness(model);
    harness.assertView((v) => v.step == SetupStep.licence);
    for (final want in [SetupStep.name, SetupStep.wifi, SetupStep.zone, SetupStep.done, SetupStep.done]) {
      harness.dispatch(SetupAction.next);
      harness.assertView((v) => v.step == want, because: 'expected $want');
    }
    harness.dispatch(SetupAction.back);
    harness.assertView((v) => v.step == SetupStep.zone);
    harness.verify(
      fresh: SetupModel.new,
      probes: const [SetupAction.next, SetupAction.back, SetupName(''), SetupPickZone('Europe/London')],
      routes: const ['again', ''],
      openAt: SetupOpened.new,
    );
  });

  test('a name is required before leaving its step', () {
    final model = SetupModel();
    final h = StoreHarness(model)
      ..dispatch(SetupAction.next)
      ..dispatch(const SetupName('   '));
    h.assertView((v) => v.step == SetupStep.name && v.error == 'The device needs a name');
    h.dispatch(const SetupName('Kitchen'));
    h.assertView((v) => v.step == SetupStep.wifi && v.error == null);
  });

  // plan 0011 D5: the again route reaches the applet; any other route,
  // and an unknown one (it arrives as the root), is the first boot
  test('opened at again, the walk restarts and its end saves; anything else is the first boot', () {
    final model = SetupModel();
    final harness = StoreHarness(model)
      ..dispatch(SetupAction.next)
      ..dispatch(SetupAction.next)
      ..dispatch(SetupAction.next);
    harness.assertView((v) => v.step == SetupStep.zone);
    harness.dispatch(const SetupOpened('again'));
    harness.assertView((v) => v.again && v.step == SetupStep.licence);
    harness.dispatch(const SetupOpened(''));
    harness.assertView((v) => !v.again);
  });
}
