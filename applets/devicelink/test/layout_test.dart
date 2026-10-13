import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_check/vrx_check.dart';
import 'package:vrx_kit/vrx_kit.dart';

import 'package:devicelink_applet/main.dart';
import 'package:devicelink_applet/state.dart';

/// Every Device Link screen on every display vrx drives (vrx_check,
/// AGENTS.md rule 11).
void main() {
  const phones = [
    BluetoothDevice(id: '/org/bluez/hci0/dev_1', name: 'Pixel 9 Pro XL of a long-named person', connected: true),
    BluetoothDevice(id: '/org/bluez/hci0/dev_2', name: 'iPhone'),
  ];
  LinkModel model(BluetoothState b, {BluetoothPairing? asking, String? showing, String? error, String? notice, int? until}) =>
      LinkModel(now: () => DateTime(2026, 10, 14, 14, 20).millisecondsSinceEpoch)
        ..bt = b
        ..asking = asking
        ..showing = showing
        ..error = error
        ..notice = notice
        ..visibleUntil = until;
  final screens = {
    'no bluetooth': () => model(const BluetoothState(present: false, on: false)),
    'not allowed': () => model(const BluetoothState(present: true, on: true, allowed: false)),
    'off': () => model(const BluetoothState(present: true, on: false)),
    'on, none paired': () => model(const BluetoothState(present: true, on: true, name: 'hi')),
    'paired': () => model(const BluetoothState(present: true, on: true, name: 'hi', devices: phones)),
    'window open': () => model(
          const BluetoothState(present: true, on: true, discoverable: true, name: 'Kitchen clock', devices: phones),
          until: DateTime(2026, 10, 14, 14, 23).millisecondsSinceEpoch,
          notice: 'Bluetooth is on now.',
        ),
    'asking, passkey': () => model(const BluetoothState(present: true, on: true, discoverable: true),
        asking: BluetoothPairing(device: '/org/bluez/hci0/dev_3', name: 'Pixel 9 Pro XL', passkey: 123456)),
    'asking, yes or no': () => model(const BluetoothState(present: true, on: true, discoverable: true),
        asking: BluetoothPairing(device: '/org/bluez/hci0/dev_3', name: 'Car audio')),
    'device': () => model(const BluetoothState(present: true, on: true, devices: phones), showing: '/org/bluez/hci0/dev_1'),
    'refused': () => model(const BluetoothState(present: true, on: false), error: 'Bluetooth is switched off. Turn it on first.'),
  };
  for (final display in allDisplays) {
    for (final s in screens.entries) {
      testWidgets('devicelink ${s.key} on ${display.name}', (tester) async {
        await expectCleanLayout(tester, LinkApplet(s.value()), display: display);
      });
    }
  }
}
