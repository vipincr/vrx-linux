import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

import 'package:wifi_applet/state.dart';

WifiNetwork net(String name, int strength, {String state = 'idle', bool secured = true, bool saved = false}) =>
    WifiNetwork(id: '/net/connman/service/$name', name: name, strength: strength, secured: secured, state: state, saved: saved);

void main() {
  test('the connected network leads; the rest are nearby', () {
    final model = WifiModel();
    final harness = StoreHarness(model);
    model.network = NetworkState(
      wifiPresent: true,
      wifiOn: true,
      networks: [
        const WifiNetwork(id: '/h', name: 'home', strength: 80, secured: true, state: 'online', saved: true, address: '192.168.1.42'),
        net('cafe', 60),
        net('far', 10),
      ],
      ethernet: 'ready',
      ethernetAddress: '10.10.10.8',
    );
    harness.dispatch(WifiAction.networkChanged);
    harness.assertView((v) => v.connected?.name == 'home' && v.nearby.map((n) => n.name).join(',') == 'cafe,far');
    // the Wi-Fi link's own address, never the cable's (the bench bug)
    harness.assertView((v) => v.connected?.address == '192.168.1.42');
  });

  test('signal glyphs bucket by strength', () {
    expect(signalGlyph(90), 'signal_wifi_4_bar');
    expect(signalGlyph(55), 'network_wifi_3_bar');
    expect(signalGlyph(30), 'network_wifi_2_bar');
    expect(signalGlyph(5), 'network_wifi_1_bar');
    for (final g in ['signal_wifi_4_bar', 'network_wifi_3_bar', 'network_wifi_2_bar', 'network_wifi_1_bar']) {
      expect(VrxSymbols.named(g), isNotNull, reason: g);
    }
  });

  test('an error clears when the person moves on, not on a network change', () {
    final model = WifiModel();
    final harness = StoreHarness(model);
    model.error = 'invalid key';
    harness.dispatch(WifiAction.failed);
    harness.dispatch(WifiAction.networkChanged);
    harness.assertView((v) => v.error == 'invalid key');
    harness.dispatch(WifiAction.asked);
    harness.assertView((v) => v.error == null);
  });
}
