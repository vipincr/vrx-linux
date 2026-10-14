import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

import 'package:wifi_applet/state.dart';

WifiNetwork net(String name, int strength, {String state = 'idle', bool secured = true, bool saved = false}) =>
    WifiNetwork(id: '/net/connman/service/$name', name: name, strength: strength, secured: secured, state: state, saved: saved);

void main() {
  test('the connected network leads; the rest are nearby', () {
    final model = WifiModel();
    final harness = StoreHarness(model);
    harness.dispatch(WifiFacts(network: NetworkState(
      wifiPresent: true,
      wifiOn: true,
      networks: [
        const WifiNetwork(id: '/h', name: 'home', strength: 80, secured: true, state: 'online', saved: true, address: '192.168.1.42'),
        net('cafe', 60),
        net('far', 10),
      ],
      ethernet: const WiredLink(state: 'ready', interface: 'eth0', address: '10.10.10.8'),
    )));
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
    harness.dispatch(const WifiFacts(error: Change('invalid key')));
    harness.dispatch(const WifiFacts(network: NetworkState(wifiPresent: true, wifiOn: true, networks: [], ethernet: WiredLink(state: 'idle', interface: 'eth0'))));
    harness.assertView((v) => v.error == 'invalid key');
    harness.dispatch(const WifiAsk(null));
    harness.assertView((v) => v.error == null);
  });

  // plan 0011 D13: a tap on a saved network joins it (it used to forget
  // it); a second tap while joining is not a second join
  test('one join at a time; a joined or joining network is not joined again', () {
    final model = WifiModel();
    final h = StoreHarness(model);
    final saved = net('home', 70, saved: true);
    expect(model.canJoin(saved), isTrue);
    h.dispatch(WifiJoinStarted(saved.id));
    expect(model.canJoin(saved), isFalse, reason: 'a double tap');
    expect(model.canJoin(net('cafe', 60)), isFalse, reason: 'one join at a time');
    h.dispatch(WifiAction.joinEnded);
    expect(model.canJoin(net('cafe', 60)), isTrue);
    expect(model.canJoin(net('x', 50, state: 'association')), isFalse);
    expect(model.canJoin(net('y', 50, state: 'online')), isFalse);
  });

  test("a network's screen follows connman, and closes when it leaves range", () {
    final model = WifiModel();
    final harness = StoreHarness(model);
    NetworkState state(List<WifiNetwork> networks) =>
        NetworkState(wifiPresent: true, wifiOn: true, networks: networks, ethernet: const WiredLink(state: 'idle', interface: 'eth0'));
    harness.dispatch(WifiFacts(network: state([net('home', 70, state: 'online', saved: true)])));
    harness.dispatch(const WifiShow('/net/connman/service/home'));
    harness.assertView((v) => v.showing?.connected == true);
    harness.dispatch(WifiFacts(network: state([net('home', 70, state: 'idle', saved: true)])));
    harness.assertView((v) => v.showing?.connected == false);
    harness.dispatch(const WifiShow('/net/connman/service/home'));
    harness.verify(
      fresh: WifiModel.new,
      probes: [WifiAction.back, WifiAction.joinEnded, WifiAsk(net('cafe', 60)), const WifiAsk(null)],
    );
    harness.dispatch(WifiFacts(network: state(const [])));
    harness.assertView((v) => v.showing == null);
  });
}
