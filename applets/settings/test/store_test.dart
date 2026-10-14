import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

import 'package:settings_applet/state.dart';

void main() {
  test('a device offers only what it has (plan 0008 D12)', () {
    final model = SettingsModel();
    final harness = StoreHarness(model);
    // no power grant: no Power. Display is always there (Settings is on a
    // screen), whatever the backlight (plan 0010 D9)
    harness.assertView((v) => v.categories.map((c) => c.category).toList().toString() ==
        [SettingsCategory.display, SettingsCategory.time, SettingsCategory.network, SettingsCategory.device].toString());
    model.canPowerOff = true;
    harness.dispatch(SettingsAction.factsChanged);
    harness.assertView((v) => v.categories.first.category == SettingsCategory.display &&
        v.categories.first.summary == 'Off after 2 min' &&
        v.categories.any((c) => c.category == SettingsCategory.power));
  });

  test('no light switch; brightness only where the screen dims (plan 0010 D1, D8)', () {
    final model = SettingsModel()..open = SettingsCategory.display;
    final h = StoreHarness(model);
    Iterable<String> keys() => h.view.rows.map((r) => r.key);
    expect(keys(), isNot(contains('light')), reason: 'the screen is never made dark by hand');
    expect(keys(), isNot(contains('brightness')), reason: 'the compositor has not said it can dim');
    model
      ..dimming = VrxDimming.alpha
      ..screen = const ScreenState(brightness: 0, lightOff: 60);
    h.dispatch(SettingsAction.factsChanged);
    final row = h.view.rows.firstWhere((r) => r.key == 'brightness');
    expect(row.kind, RowKind.slider);
    expect(row.level, 0, reason: '0 is the floor the compositor keeps visible');
    expect(keys(), isNot(contains('light')));
  });

  test('the screen-off row reads the screen settings and steps through the choices', () {
    final model = SettingsModel()..open = SettingsCategory.display;
    final harness = StoreHarness(model);
    String row() => harness.view.rows.firstWhere((r) => r.key == 'light_off').value;
    // no file yet: the compositor's default
    expect(row(), '2 min');
    expect(model.nextLightOff, 300);
    model.screen = const ScreenState(lightOff: 0);
    harness.dispatch(SettingsAction.factsChanged);
    expect(row(), 'Never');
    expect(model.nextLightOff, 30);
    model.screen = const ScreenState(lightOff: 600);
    expect(model.nextLightOff, 0, reason: 'the last choice wraps to never');
    // a value written by hand that is not a choice steps to the first
    model.screen = const ScreenState(lightOff: 45);
    expect(model.nextLightOff, 0);
    expect(lightOffLabel(45), '45 s');
  });

    test('the colour scheme: offered on a colour panel, pending until a restart', () {
    final model = SettingsModel()..open = SettingsCategory.display;
    final h = StoreHarness(model);
    expect(h.view.rows.map((r) => r.key), isNot(contains('scheme')), reason: 'a grey panel draws no scheme');
    model.runningScheme = 12;
    h.dispatch(SettingsAction.factsChanged);
    SettingRow row(String key) => h.view.rows.firstWhere((r) => r.key == key);
    expect(row('scheme').value, 'Amber complementary');
    expect(row('polarity').on, isTrue);
    expect(h.view.rows.map((r) => r.key), isNot(contains('restart')), reason: 'nothing to apply yet');
    model.values['vrx'] = {'scheme': '3', 'polarity': 'light'};
    h.dispatch(SettingsAction.factsChanged);
    expect(row('scheme').value, 'Blue split complementary');
    expect(row('polarity').on, isFalse);
    expect(row('restart').label, 'Restart to apply');
    // a hand-edited value that is not a scheme reads as the running one
    model.values['vrx'] = {'scheme': '99'};
    h.dispatch(SettingsAction.factsChanged);
    expect(row('scheme').value, 'Amber complementary');
    expect(h.view.rows.map((r) => r.key), isNot(contains('restart')));
  });

  test('the time rows read the time service', () {
    final model = SettingsModel()..open = SettingsCategory.time;
    final harness = StoreHarness(model);
    harness.assertView((v) => v.rows.first.value == '…', because: 'nothing read yet');
    model.time = const TimeState(zone: 'Asia/Kolkata', automatic: true, synced: true);
    harness.dispatch(SettingsAction.factsChanged);
    final rows = harness.view.rows;
    expect(rows.firstWhere((r) => r.key == 'zone').value, 'Asia/Kolkata');
    expect(rows.firstWhere((r) => r.key == 'automatic').on, isTrue);
    expect(rows.firstWhere((r) => r.key == 'synced').value, 'Synchronised');
  });

  test('the network rows read connman; no Wi-Fi row without Wi-Fi', () {
    final model = SettingsModel()..open = SettingsCategory.network;
    final harness = StoreHarness(model);
    model.network = const NetworkState(wifiPresent: false, wifiOn: false, networks: [], ethernet: 'online', ethernetAddress: '10.10.10.8');
    harness.dispatch(SettingsAction.factsChanged);
    final keys = harness.view.rows.map((r) => r.key).toList();
    expect(keys, ['ethernet']);
    expect(harness.view.rows.first.value, '10.10.10.8');
  });

  test('Device lists only what the device reports, no placeholders', () {
    final model = SettingsModel()..open = SettingsCategory.device;
    final harness = StoreHarness(model);
    harness.assertView((v) => v.rows.isEmpty, because: 'nothing read yet: nothing shown');
    model.device = const DeviceState(name: 'vrxboard-cm4', hostname: 'vrxboard-cm4', model: 'Raspberry Pi Compute Module 4 Rev 1.1', version: '0.1.0074 (cm4-bcm2711)', memoryMb: 1843);
    harness.dispatch(SettingsAction.factsChanged);
    final keys = harness.view.rows.map((r) => r.key).toList();
    // no network-name row when it equals the name; no serial when unknown
    expect(keys, ['name', 'model', 'version', 'memory', 'manage', 'licences', 'setup']);
    expect(harness.view.rows.firstWhere((r) => r.key == 'memory').value, '1.8 GB');
    // USB only on a board with a device port
    model.usbPresent = true;
    harness.dispatch(SettingsAction.factsChanged);
    expect(harness.view.rows.map((r) => r.key), contains('usbport'));
    // Device Link only where connman has a Bluetooth radio
    expect(harness.view.rows.map((r) => r.key), isNot(contains('devicelink')));
    model.bluetooth = const BluetoothState(present: true, on: false);
    harness.dispatch(SettingsAction.factsChanged);
    expect(harness.view.rows.firstWhere((r) => r.key == 'devicelink').value, 'Off');
    model.bluetooth = const BluetoothState(present: true, on: true, devices: [
      BluetoothDevice(id: '/org/bluez/hci0/dev_1', name: 'Pixel'),
      BluetoothDevice(id: '/org/bluez/hci0/dev_2', name: 'iPhone'),
    ]);
    harness.dispatch(SettingsAction.factsChanged);
    expect(harness.view.rows.firstWhere((r) => r.key == 'devicelink').value, '2 paired');
  });

  test('a failure shows until the person moves on', () {
    final model = SettingsModel();
    final harness = StoreHarness(model);
    model.error = 'not allowed';
    harness.dispatch(SettingsAction.failed);
    harness.assertView((v) => v.error == 'not allowed');
    harness.dispatch(SettingsAction.factsChanged);
    harness.assertView((v) => v.error == 'not allowed', because: 'a fact change is not the person moving on');
    harness.dispatch(SettingsAction.navigated);
    harness.assertView((v) => v.error == null);
  });

  test('applets\' declared settings: a category, values from the files, enums cycle', () {
    final model = SettingsModel()
      ..declared = const [
        AppletSettingsDecl(id: 'clock', name: 'Clock', settings: [
          SettingDecl(key: 'clock_format', label: 'Time format', category: 'Clock', type: 'enum', defaultValue: '24h', options: ['24h', '12h']),
          SettingDecl(key: 'chime', label: 'Hourly chime', category: 'Clock', type: 'bool', defaultValue: 'false'),
        ]),
      ];
    final h = StoreHarness(model);
    h.assertView((v) => v.categories.any((c) => c.category == SettingsCategory.applets));
    model.open = SettingsCategory.applets;
    h.dispatch(SettingsAction.navigated);
    h.assertView((v) => v.rows.first.label == 'Clock: Time format' && v.rows.first.value == '24h' && v.rows.last.value == 'Off');
    final decl = model.declOf('clock', 'clock_format')!;
    expect(model.nextValue('clock', decl), '12h');
    model.values['clock'] = {'clock_format': '12h', 'chime': 'true'};
    h.dispatch(SettingsAction.factsChanged);
    h.assertView((v) => v.rows.first.value == '12h' && v.rows.last.value == 'On');
    expect(model.nextValue('clock', decl), '24h');
  });

  // plan 0011 D12, D14, D7: rows follow what the services can do
  test('time rows: set the clock only while network time cannot, the format from the locales', () {
    final model = SettingsModel()
      ..open = SettingsCategory.time
      ..time = const TimeState(zone: 'Asia/Kolkata', automatic: true, synced: true);
    final h = StoreHarness(model);
    h.assertView((v) => !v.rows.any((r) => r.key == 'set_time') && !v.rows.any((r) => r.key == 'time_format'));
    model
      ..time = const TimeState(zone: 'Asia/Kolkata', automatic: false, synced: true)
      ..timeLocales = const [TimeLocale(name: 'en_GB.utf8', timeFormat: '%T', dateFormat: '%d/%m/%y')]
      ..timeLocale = 'en_GB.utf8';
    h.dispatch(SettingsAction.factsChanged);
    h.assertView((v) => v.rows.any((r) => r.key == 'set_time') && v.rows.any((r) => r.key == 'set_date'));
    h.assertView((v) => v.rows.firstWhere((r) => r.key == 'time_format').value == '13:05:00 · 14/10/26');
  });

  test('a battery is a Power row only where one exists', () {
    final model = SettingsModel()..open = SettingsCategory.power;
    final h = StoreHarness(model);
    h.assertView((v) => !v.categories.any((c) => c.category == SettingsCategory.power));
    model.battery = const Battery(name: 'BAT0', percent: 41, charging: true);
    h.dispatch(SettingsAction.factsChanged);
    h.assertView((v) => v.rows.firstWhere((r) => r.key == 'battery').value == '41 %, charging');
    h.assertView((v) => v.categories.firstWhere((c) => c.category == SettingsCategory.power).summary == '41 %');
  });

  test('Battery use and Why it is awake: offered where vrxhost estimates (plan 0012 D12)', () {
    final model = SettingsModel();
    final h = StoreHarness(model);
    h.assertView((v) => v.categories.every((c) => c.category != SettingsCategory.power),
        because: 'off-device, with no power off and no battery, there is no Power');
    model.energyAvailable = true;
    h.dispatch(SettingsAction.factsChanged);
    h.assertView((v) => v.categories.any((c) => c.category == SettingsCategory.power), because: 'the estimate is a Power row');
    model.open = SettingsCategory.power;
    h.dispatch(SettingsAction.navigated);
    h.assertView((v) => v.rows.map((r) => r.key).toList().join(',') == 'battery_use,why_awake',
        because: 'both open their screens; nothing else on this device');
  });
}
