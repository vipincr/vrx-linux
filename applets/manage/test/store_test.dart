import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

import 'package:manage_applet/state.dart';

void main() {
  test('addresses: each link, then the .local name; a fact clears a refusal', () {
    final model = ManageModel();
    final h = StoreHarness(model);
    h.assertView((v) => v.serving == null && v.addresses.isEmpty, because: 'nothing read yet');
    model
      ..servingNow(true)
      ..hostname = 'gg'
      ..ips = ['10.10.10.8', ''];
    h.dispatch(ManageAction.factsChanged);
    h.assertView((v) => v.serving == true && v.addresses.join(' ') == 'http://10.10.10.8 http://gg.local');
    model.error = 'refused';
    h.dispatch(ManageAction.failed);
    h.assertView((v) => v.error == 'refused');
    h.dispatch(ManageAction.factsChanged);
    h.assertView((v) => v.error == null);
  });

  // plan 0011 D15: vrx-manage stops itself after ten idle minutes
  test('a stop nobody asked for is the idle stop; one asked for is not', () {
    final model = ManageModel()..servingNow(true);
    model.servingNow(false);
    expect(model.stoppedIdle, isTrue);
    model.servingNow(true);
    expect(model.stoppedIdle, isFalse);
    model
      ..askedStop = true
      ..servingNow(false);
    expect(model.stoppedIdle, isFalse);
  });

  test('serving holds the screen; stopped does not', () {
    final model = ManageModel();
    expect(model.keepsScreenOn, isNull);
    model.servingNow(true);
    expect(model.keepsScreenOn, isNotNull);
  });

  test('no network offers hosting; the hosted network has a name, a passphrase and a code', () {
    final model = ManageModel()
      ..servingNow(true)
      ..hostname = 'kitchen';
    final h = StoreHarness(model);
    h.assertView((v) => v.onNoNetwork);
    model
      ..hosting = true
      ..ssid = hostedName(model.hostname)
      ..passphrase = hostedPassphrase(Random(1))
      ..hostedAddress = '192.168.0.1';
    h.dispatch(ManageAction.hosting);
    h.assertView((v) => !v.onNoNetwork && v.addresses.first == 'http://192.168.0.1');
    h.assertView((v) => v.ssid == 'vrx-kitchen' && v.passphrase.length == 12 && !RegExp('[01lIO]').hasMatch(v.passphrase));
    h.assertView((v) => v.wifiQr == 'WIFI:T:WPA;S:vrx-kitchen;P:${v.passphrase};;');
    expect(hostedName('x' * 40).length, 32);
  });
}
