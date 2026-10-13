import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

import 'package:manage_applet/state.dart';

void main() {
  test('addresses: the .local name, then each link; a fact clears a refusal', () {
    final model = ManageModel();
    final h = StoreHarness(model);
    h.assertView((v) => v.serving == null && v.addresses.isEmpty, because: 'nothing read yet');
    model
      ..serving = true
      ..hostname = 'gg'
      ..ips = ['10.10.10.8', ''];
    h.dispatch(ManageAction.factsChanged);
    h.assertView((v) => v.serving == true && v.addresses.join(' ') == 'http://gg.local http://10.10.10.8');
    model.error = 'refused';
    h.dispatch(ManageAction.failed);
    h.assertView((v) => v.error == 'refused');
    h.dispatch(ManageAction.factsChanged);
    h.assertView((v) => v.error == null);
  });
}
