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
    ..dimming = VrxDimming.alpha
    ..screen = const ScreenState(brightness: 40, lightOff: 600)
    // a colour panel drawing scheme 12, with 13 chosen: the longest Display
    ..runningScheme = 12
    ..values['vrx'] = {'scheme': '13', 'polarity': 'light'}
    ..canPowerOff = true
    ..supplyLow = true
    ..zones = ['America/Argentina/Buenos_Aires', 'Asia/Kolkata', 'Europe/London']
    ..declared = const [
      AppletSettingsDecl(id: 'clock', name: 'Clock', settings: [
        SettingDecl(key: 'clock_format', label: 'Time format', category: 'Clock', type: 'enum', defaultValue: '24h', options: ['24h', '12h']),
      ]),
      AppletSettingsDecl(id: 'recorder', name: 'Recorder', settings: [
        SettingDecl(key: 'sample_rate', label: 'Sample rate', category: 'Recorder', type: 'int', defaultValue: '44100'),
      ]),
    ];
  final screens = <String, SettingsModel Function()>{
    'categories': model,
    for (final c in SettingsCategory.values) c.name: () => model()..open = c,
    'setting entry': () => model()
      ..open = SettingsCategory.applets
      ..editingSetting = ('recorder', 'sample_rate'),
    'rename': () => model()
      ..open = SettingsCategory.device
      ..renaming = true,
    'zone': () => model()
      ..open = SettingsCategory.time
      ..pickingZone = true,
    'colour scheme': () => model()
      ..open = SettingsCategory.display
      ..pickingScheme = true,
  };
  // every setting every repo applet declares, as Settings > Applets shows
  // it: a new applet's labels are measured with no new test
  final repoDeclared = [
    for (final m in repoManifests())
      if (m.settings.isNotEmpty)
        AppletSettingsDecl(id: m.id, name: m.name, settings: [
          for (final s in m.settings)
            SettingDecl(key: s.key, label: s.label, category: m.name, type: s.type, defaultValue: s.defaultValue, options: s.options),
        ]),
  ];
  screens['applets in the repo'] = () => model()
    ..declared = repoDeclared
    ..open = SettingsCategory.applets;
  for (final display in allDisplays) {
    for (final s in screens.entries) {
      testWidgets('settings ${s.key} on ${display.name}', (tester) async {
        await expectCleanLayout(tester, SettingsApplet(s.value()), display: display);
      });
    }
  }
}
