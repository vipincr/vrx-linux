import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_check/vrx_check.dart';
import 'package:vrx_kit/vrx_kit.dart';

import 'package:settings_applet/main.dart';
import 'package:settings_applet/state.dart';

/// Every Settings screen holds on every display vrx drives (vrx_check).
void main() {
  SettingsModel model() => SettingsModel()
    // network time off: the set-the-time rows show
    ..time = const TimeState(zone: 'America/Argentina/Buenos_Aires', automatic: false, synced: false)
    ..timeLocales = const [
      TimeLocale(name: 'en_GB.utf8', timeFormat: '%T', dateFormat: '%d/%m/%y'),
      TimeLocale(name: 'en_US.utf8', timeFormat: '%r', dateFormat: '%m/%d/%Y'),
    ]
    ..timeLocale = 'en_US.utf8'
    ..battery = const Battery(name: 'BAT0', percent: 41, charging: true, volts: 3.912)
    ..usage = const DeviceUsage(memoryFreeMb: 1457, dataFreeMb: 11571, dataTotalMb: 13004, rootFreeMb: 388)
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
    // the longest Device Link value: a connected phone's name
    ..bluetooth = const BluetoothState(present: true, on: true, devices: [
      BluetoothDevice(id: '/org/bluez/hci0/dev_1', name: 'Pixel 9 Pro XL of a long-named person', connected: true),
    ])
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
    'time format': () => model()
      ..open = SettingsCategory.time
      ..pickingTimeFormat = true,
    'set the date': () => model()
      ..open = SettingsCategory.time
      ..settingTime = SettingTime.date,
    'set the time': () => model()
      ..open = SettingsCategory.time
      ..settingTime = SettingTime.time,
    // plan 0012 D13, D14: a board that offers both later steps, with the
    // longest values they take
    'display with sleep and deep sleep': () => model()
      ..open = SettingsCategory.display
      ..cascade = const VrxCascade(sleep: true, deep: true, wakeAlarm: true)
      ..screen = const ScreenState(brightness: 40, lightOff: 600, sleepAfter: 1800, deepAfter: 7200),
    // plan 0012 D12: the longest names and values a ranking holds
    'battery use': () => model()
      ..energyAvailable = true
      ..open = SettingsCategory.power
      ..showingUse = true
      ..energy = _report,
    'battery use, not calibrated': () => model()
      ..energyAvailable = true
      ..open = SettingsCategory.power
      ..showingUse = true
      ..energy = const EnergyReport(calibrated: false, hours: 24, rows: [
        EnergyRow(key: 'assistant', name: 'Assistant', system: false, millijoules: null, cpuMs: 4800000, gpuMs: 600000, wakeups: 900, frontSeconds: 0, over: true),
      ]),
    'why it is awake': () => model()
      ..energyAvailable = true
      ..open = SettingsCategory.power
      ..showingAwake = true
      ..energy = _report
      ..awake = const AwakeReport(
        inhibitors: [AwakeInhibitor(what: 'idle', who: 'clock', why: 'an alarm or timer is ringing', mode: 'block', applet: 'clock')],
        running: ['clock', 'launcher', 'settings', 'shell', 'stt'],
        frozen: ['assistant', 'recorder', 'scripts', 'terminal', 'web'],
        wakeups: [('mmc1', 120), ('Goodix Capacitive TouchScreen', 42)],
        governor: 'schedutil',
        khz: 1500000,
        tempMilliC: 51200,
        supplyLow: true,
        screenOn: true,
      ),
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

const _report = EnergyReport(calibrated: true, measured: '2026-10-14 with fnb58', hours: 24, rows: [
  EnergyRow(key: 'system:floor', name: 'Idle floor', system: true, millijoules: 98000000, cpuMs: 0, gpuMs: 0, wakeups: 0, frontSeconds: 0, over: false),
  EnergyRow(key: 'system:screen', name: 'Screen', system: true, millijoules: 31000000, cpuMs: 0, gpuMs: 0, wakeups: 0, frontSeconds: 0, over: false),
  EnergyRow(key: 'web', name: 'Web requests', system: false, millijoules: 2400000, cpuMs: 340000, gpuMs: 60000, wakeups: 7000, frontSeconds: 4800, over: true),
  EnergyRow(key: 'assistant', name: 'Assistant', system: false, millijoules: 1200, cpuMs: 1200, gpuMs: 0, wakeups: 12, frontSeconds: 0, over: false),
]);
