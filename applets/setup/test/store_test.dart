import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

import 'package:setup_applet/state.dart';

void main() {
  test('the walk moves one step at a time, in evrx-rt order', () {
    final model = SetupModel();
    final harness = StoreHarness(model);
    harness.assertView((v) => v.step == SetupStep.licence);
    for (final want in [SetupStep.name, SetupStep.wifi, SetupStep.zone, SetupStep.done, SetupStep.done]) {
      model.next();
      harness.dispatch(SetupAction.moved);
      harness.assertView((v) => v.step == want, because: 'expected $want');
    }
    model.back();
    harness.dispatch(SetupAction.moved);
    harness.assertView((v) => v.step == SetupStep.zone);
  });

  test('a name is required before leaving its step', () {
    final model = SetupModel()..name = '   ';
    expect(model.canLeaveName, isFalse);
    model.name = 'Kitchen';
    expect(model.canLeaveName, isTrue);
  });
}
