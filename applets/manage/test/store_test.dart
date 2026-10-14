import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

import 'package:manage_applet/state.dart';

void main() {
  test('addresses: each link, then the .local name; a fact clears a refusal', () {
    final model = ManageModel();
    final h = StoreHarness(model);
    h.assertView((v) => v.serving == null && v.addresses.isEmpty, because: 'nothing read yet');
    h.dispatch(const ManageFacts(serving: true, hostname: 'gg', ips: ['10.10.10.8', '']));
    h.assertView((v) => v.serving == true && v.addresses.join(' ') == 'http://10.10.10.8 http://gg.local');
    h.dispatch(const ManageFacts(error: Change('refused')));
    h.assertView((v) => v.error == 'refused');
    h.dispatch(const ManageFacts(hostname: 'gg'));
    h.assertView((v) => v.error == null);
    h.verify(fresh: ManageModel.new, probes: const [ManageAction.askStop, ManageFacts(serving: false)]);
  });

  // plan 0011 D15: vrx-manage stops itself after ten idle minutes
  test('a stop nobody asked for is the idle stop; one asked for is not', () {
    final model = ManageModel();
    final h = StoreHarness(model)
      ..dispatch(const ManageFacts(serving: true))
      ..dispatch(const ManageFacts(serving: false));
    expect(model.stoppedIdle, isTrue);
    h.dispatch(const ManageFacts(serving: true));
    expect(model.stoppedIdle, isFalse);
    h
      ..dispatch(ManageAction.askStop)
      ..dispatch(const ManageFacts(serving: false));
    expect(model.stoppedIdle, isFalse);
  });

  test('serving holds the screen; stopped does not', () {
    final model = ManageModel();
    final h = StoreHarness(model);
    expect(model.keepsScreenOn, isNull);
    h.dispatch(const ManageFacts(serving: true));
    expect(model.keepsScreenOn, isNotNull);
  });

  test('no network offers hosting; the hosted network has a name, a passphrase and a code', () {
    final model = ManageModel();
    final h = StoreHarness(model)..dispatch(const ManageFacts(serving: true, hostname: 'kitchen'));
    h.assertView((v) => v.onNoNetwork);
    h.dispatch(ManageHosted(
        on: true, ssid: hostedName(model.hostname), passphrase: hostedPassphrase(Random(1)), address: '192.168.0.1'));
    h.assertView((v) => !v.onNoNetwork && v.addresses.first == 'http://192.168.0.1');
    h.assertView((v) => v.ssid == 'vrx-kitchen' && v.passphrase.length == 12 && !RegExp('[01lIO]').hasMatch(v.passphrase));
    h.assertView((v) => v.wifiQr == 'WIFI:T:WPA;S:vrx-kitchen;P:${v.passphrase};;');
    expect(hostedName('x' * 40).length, 32);
  });
}
