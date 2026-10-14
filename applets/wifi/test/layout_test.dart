import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_check/vrx_check.dart';
import 'package:vrx_kit/vrx_kit.dart';

import 'package:wifi_applet/main.dart';
import 'package:wifi_applet/state.dart';

/// The Wi-Fi screens hold on every display vrx drives (vrx_check).
void main() {
  const nets = [
    WifiNetwork(id: 'a', name: 'Bench network 5GHz', strength: 80, secured: true, state: 'online', saved: true, address: '192.168.1.42'),
    WifiNetwork(id: 'b', name: 'A neighbour with a very long network name', strength: 40, secured: true, state: 'idle', saved: false),
    WifiNetwork(id: 'c', name: 'Cafe', strength: 20, secured: false, state: 'idle', saved: false),
  ];
  WifiModel model() => WifiModel()
    ..network = const NetworkState(wifiPresent: true, wifiOn: true, ethernet: WiredLink(state: 'online', interface: 'eth0', address: '10.10.10.8'), networks: nets);
  for (final display in allDisplays) {
    testWidgets('wifi list on ${display.name}', (tester) async {
      await expectCleanLayout(tester, WifiApplet(model()), display: display);
    });
    testWidgets('a network screen on ${display.name}', (tester) async {
      await expectCleanLayout(tester, WifiApplet(model()..showing = 'a'), display: display);
    });
    testWidgets('wifi passphrase on ${display.name}', (tester) async {
      await expectCleanLayout(tester, WifiApplet(model()..asking = nets[1]), display: display);
    });
  }
}
