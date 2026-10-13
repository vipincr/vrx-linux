import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_check/vrx_check.dart';
import 'package:vrx_kit/vrx_kit.dart';

import 'package:settings_applet/main.dart';
import 'package:settings_applet/state.dart';

/// Every Settings screen holds on every display vrx drives (vrx_check).
void main() {
  SettingsModel model() => SettingsModel()
    ..time = const TimeState(zone: 'America/Argentina/Buenos_Aires', automatic: true, synced: true)
    ..network = const NetworkState(
      wifiPresent: true,
      wifiOn: true,
      ethernet: 'online',
      ethernetAddress: '10.10.10.8',
      networks: [
        WifiNetwork(id: 'a', name: 'Bench network 5GHz', strength: 80, secured: true, state: 'online', saved: true, address: '192.168.1.42'),
      ],
    )
    ..device = const DeviceState(
      name: 'Kitchen display',
      hostname: 'kitchen-display',
      version: '0.1.0074',
      model: 'Raspberry Pi Compute Module 4 Rev 1.1',
      serial: '10000000a1b2c3d4',
      memoryMb: 3796,
    )
    ..lightLevels = 2
    ..light = true
    ..canPowerOff = true
    ..zones = ['America/Argentina/Buenos_Aires', 'Asia/Kolkata', 'Europe/London'];
  final screens = <String, SettingsModel Function()>{
    'categories': model,
    for (final c in SettingsCategory.values) c.name: () => model()..open = c,
    'rename': () => model()
      ..open = SettingsCategory.device
      ..renaming = true,
    'zone': () => model()
      ..open = SettingsCategory.time
      ..pickingZone = true,
  };
  for (final display in allDisplays) {
    for (final s in screens.entries) {
      testWidgets('settings ${s.key} on ${display.name}', (tester) async {
        await expectCleanLayout(tester, SettingsApplet(s.value()), display: display);
      });
    }
  }
}
