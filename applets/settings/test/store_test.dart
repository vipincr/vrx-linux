import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

import 'package:settings_applet/state.dart';

void main() {
  // the reduce budget times one action; a fresh test isolate compiles the
  // reducer's pattern switch and the view's rows on first use (the device
  // runs AOT, which has no such first call), so warm them once, untimed
  setUpAll(() {
    final warm = SettingsModel();
    for (final c in SettingsCategory.values) {
      warm
        ..reduce(const SettingsState(open: null, pickingZone: false), SettingsGo(open: Change(c)))
        ..reduce(const SettingsState(open: null, pickingZone: false),
            const SettingsFacts(canPowerOff: true, energyAvailable: true, screen: ScreenState(lightOff: 60)));
    }
    warm.reduce(const SettingsState(open: null, pickingZone: false), SettingsAction.back);
  });

  test('a device offers only what it has (plan 0008 D12)', () {
    final model = SettingsModel();
    final harness = StoreHarness(model);
    // no power grant: no Power. Display is always there (Settings is on a
    // screen), whatever the backlight (plan 0010 D9)
    harness.assertView((v) => v.categories.map((c) => c.category).toList().toString() ==
        [SettingsCategory.display, SettingsCategory.time, SettingsCategory.network, SettingsCategory.device].toString());
    harness.dispatch(const SettingsFacts(canPowerOff: true));
    harness.assertView((v) => v.categories.first.category == SettingsCategory.display &&
        v.categories.first.summary == 'Off after 2 min' &&
        v.categories.any((c) => c.category == SettingsCategory.power));
  });

  test('no light switch; brightness only where the screen dims (plan 0010 D1, D8)', () {
    final model = SettingsModel();
    final h = StoreHarness(model)..dispatch(const SettingsGo(open: Change(SettingsCategory.display)));
    Iterable<String> keys() => h.view.rows.map((r) => r.key);
    expect(keys(), isNot(contains('light')), reason: 'the screen is never made dark by hand');
    expect(keys(), isNot(contains('brightness')), reason: 'the compositor has not said it can dim');
    h.dispatch(const SettingsFacts(dimming: VrxDimming.alpha, screen: ScreenState(brightness: 0, lightOff: 60)));
    final row = h.view.rows.firstWhere((r) => r.key == 'brightness');
    expect(row.kind, RowKind.slider);
    expect(row.level, 0, reason: '0 is the floor the compositor keeps visible');
    expect(keys(), isNot(contains('light')));
  });

  test('the screen-off row reads the screen settings and steps through the choices', () {
    final model = SettingsModel();
    final harness = StoreHarness(model)..dispatch(const SettingsGo(open: Change(SettingsCategory.display)));
    String row() => harness.view.rows.firstWhere((r) => r.key == 'light_off').value;
    // no file yet: the compositor's default
    expect(row(), '2 min');
    expect(model.nextLightOff, 300);
    harness.dispatch(const SettingsFacts(screen: ScreenState(lightOff: 0)));
    expect(row(), 'Never');
    expect(model.nextLightOff, 30);
    harness.dispatch(const SettingsFacts(screen: ScreenState(lightOff: 600)));
    expect(model.nextLightOff, 0, reason: 'the last choice wraps to never');
    // a value written by hand that is not a choice steps to the first
    harness.dispatch(const SettingsFacts(screen: ScreenState(lightOff: 45)));
    expect(model.nextLightOff, 0);
    expect(lightOffLabel(45), '45 s');
  });

  test('the cascade rows: only where the board offers them, each later than the step before (plan 0012 D13)', () {
    final model = SettingsModel();
    final h = StoreHarness(model)..dispatch(const SettingsGo(open: Change(SettingsCategory.display)));
    Iterable<String> keys() => h.view.rows.map((r) => r.key);
    expect(keys(), isNot(contains('sleep_after')), reason: 'no sleep offered: no row (the CM4)');
    expect(keys(), isNot(contains('deep_after')), reason: 'no timed wake: no power off when idle');
    h.dispatch(const SettingsFacts(cascade: VrxCascade(sleep: true, deep: true, wakeAlarm: true), screen: ScreenState(lightOff: 600)));
    SettingRow row(String key) => h.view.rows.firstWhere((r) => r.key == key);
    expect(row('sleep_after').value, 'Never');
    expect(row('deep_after').value, 'Never');
    expect(model.nextSleepAfter, 1800, reason: 'later than the screen goes off (10 min)');
    h.dispatch(const SettingsFacts(screen: ScreenState(lightOff: 600, sleepAfter: 1800)));
    expect(model.nextDeepAfter, 3600, reason: 'later than sleep');
    h.dispatch(const SettingsFacts(screen: ScreenState(lightOff: 600, sleepAfter: 1800, deepAfter: 7200)));
    expect(row('deep_after').value, 'After 2 h');
    expect(model.nextDeepAfter, 0, reason: 'the last choice wraps to never');
  });

    test('the colour scheme: offered on a colour panel, pending until a restart', () {
    final model = SettingsModel();
    final h = StoreHarness(model)..dispatch(const SettingsGo(open: Change(SettingsCategory.display)));
    expect(h.view.rows.map((r) => r.key), isNot(contains('scheme')), reason: 'a grey panel draws no scheme');
    h.dispatch(const SettingsFacts(runningScheme: 12));
    SettingRow row(String key) => h.view.rows.firstWhere((r) => r.key == key);
    expect(row('scheme').value, 'Amber complementary');
    expect(row('polarity').on, isTrue);
    expect(h.view.rows.map((r) => r.key), isNot(contains('restart')), reason: 'nothing to apply yet');
    h.dispatch(const SettingsFacts(values: ('vrx', {'scheme': '3', 'polarity': 'light'})));
    expect(row('scheme').value, 'Blue split complementary');
    expect(row('polarity').on, isFalse);
    expect(row('restart').label, 'Restart to apply');
    // a hand-edited value that is not a scheme reads as the running one
    h.dispatch(const SettingsFacts(values: ('vrx', {'scheme': '99'})));
    expect(row('scheme').value, 'Amber complementary');
    expect(h.view.rows.map((r) => r.key), isNot(contains('restart')));
  });

  test('the time rows read the time service', () {
    final harness = StoreHarness(SettingsModel())..dispatch(const SettingsGo(open: Change(SettingsCategory.time)));
    harness.assertView((v) => v.rows.first.value == '…', because: 'nothing read yet');
    harness.dispatch(const SettingsFacts(time: TimeState(zone: 'Asia/Kolkata', automatic: true, synced: true)));
    final rows = harness.view.rows;
    expect(rows.firstWhere((r) => r.key == 'zone').value, 'Asia/Kolkata');
    expect(rows.firstWhere((r) => r.key == 'automatic').on, isTrue);
    expect(rows.firstWhere((r) => r.key == 'synced').value, 'Synchronised');
  });

  test('the network rows read connman; no Wi-Fi row without Wi-Fi', () {
    final harness = StoreHarness(SettingsModel())
      ..dispatch(const SettingsGo(open: Change(SettingsCategory.network)))
      ..dispatch(const SettingsFacts(
          network: NetworkState(wifiPresent: false, wifiOn: false, networks: [], ethernet: 'online', ethernetAddress: '10.10.10.8')));
    final keys = harness.view.rows.map((r) => r.key).toList();
    expect(keys, ['ethernet']);
    expect(harness.view.rows.first.value, '10.10.10.8');
  });

  test('Device lists only what the device reports, no placeholders', () {
    final harness = StoreHarness(SettingsModel())..dispatch(const SettingsGo(open: Change(SettingsCategory.device)));
    harness.assertView((v) => v.rows.isEmpty, because: 'nothing read yet: nothing shown');
    harness.dispatch(const SettingsFacts(
        device: DeviceState(name: 'vrxboard-cm4', hostname: 'vrxboard-cm4', model: 'Raspberry Pi Compute Module 4 Rev 1.1', version: '0.1.0074 (cm4-bcm2711)', memoryMb: 1843)));
    final keys = harness.view.rows.map((r) => r.key).toList();
    // no network-name row when it equals the name; no serial when unknown
    expect(keys, ['name', 'model', 'version', 'memory', 'on_screen_keyboard', 'manage', 'licences', 'setup']);
    expect(harness.view.rows.firstWhere((r) => r.key == 'memory').value, '1.8 GB');
    // USB only on a board with a device port
    harness.dispatch(const SettingsFacts(usbPresent: true));
    expect(harness.view.rows.map((r) => r.key), contains('usbport'));
    // Device Link only where connman has a Bluetooth radio
    expect(harness.view.rows.map((r) => r.key), isNot(contains('devicelink')));
    harness.dispatch(const SettingsFacts(bluetooth: BluetoothState(present: true, on: false)));
    expect(harness.view.rows.firstWhere((r) => r.key == 'devicelink').value, 'Off');
    harness.dispatch(const SettingsFacts(bluetooth: BluetoothState(present: true, on: true, devices: [
      BluetoothDevice(id: '/org/bluez/hci0/dev_1', name: 'Pixel'),
      BluetoothDevice(id: '/org/bluez/hci0/dev_2', name: 'iPhone'),
    ])));
    expect(harness.view.rows.firstWhere((r) => r.key == 'devicelink').value, '2 paired');
  });

  test('the on-screen keyboard row reads the screen settings and steps between its two modes', () {
    final harness = StoreHarness(SettingsModel())..dispatch(const SettingsGo(open: Change(SettingsCategory.device)));
    harness.dispatch(const SettingsFacts(device: DeviceState(name: 'b', hostname: 'b')));
    SettingRow row() => harness.view.rows.firstWhere((r) => r.key == 'on_screen_keyboard');
    expect(row().value, 'Only without a keyboard', reason: 'the default (plan 0013 D6)');
    expect(nextKeyboardMode(VrxKeyboardMode.auto), VrxKeyboardMode.show);
    harness.dispatch(const SettingsFacts(screen: ScreenState(keyboard: VrxKeyboardMode.show)));
    expect(row().value, 'Show');
    expect(nextKeyboardMode(VrxKeyboardMode.show), VrxKeyboardMode.auto);
  });

  test('a failure shows until the person moves on', () {
    final harness = StoreHarness(SettingsModel())..dispatch(const SettingsFacts(error: 'not allowed'));
    harness.assertView((v) => v.error == 'not allowed');
    harness.dispatch(const SettingsFacts(canPowerOff: true));
    harness.assertView((v) => v.error == 'not allowed', because: 'a fact change is not the person moving on');
    harness.dispatch(const SettingsGo(open: Change(SettingsCategory.display)));
    harness.assertView((v) => v.error == null);
  });

  test('applets\' declared settings: a category, values from the files, enums cycle', () {
    final model = SettingsModel();
    final h = StoreHarness(model)
      ..dispatch(const SettingsFacts(declared: [
        AppletSettingsDecl(id: 'clock', name: 'Clock', settings: [
          SettingDecl(key: 'clock_format', label: 'Time format', category: 'Clock', type: 'enum', defaultValue: '24h', options: ['24h', '12h']),
          SettingDecl(key: 'chime', label: 'Hourly chime', category: 'Clock', type: 'bool', defaultValue: 'false'),
        ]),
      ]));
    h.assertView((v) => v.categories.any((c) => c.category == SettingsCategory.applets));
    h.dispatch(const SettingsGo(open: Change(SettingsCategory.applets)));
    h.assertView((v) => v.rows.first.label == 'Clock: Time format' && v.rows.first.value == '24h' && v.rows.last.value == 'Off');
    final decl = model.declOf('clock', 'clock_format')!;
    expect(model.nextValue('clock', decl), '12h');
    h.dispatch(const SettingsFacts(values: ('clock', {'clock_format': '12h', 'chime': 'true'})));
    h.assertView((v) => v.rows.first.value == '12h' && v.rows.last.value == 'On');
    expect(model.nextValue('clock', decl), '24h');
  });

  // plan 0011 D12, D14, D7: rows follow what the services can do
  test('time rows: set the clock only while network time cannot, the format from the locales', () {
    final h = StoreHarness(SettingsModel())
      ..dispatch(const SettingsGo(open: Change(SettingsCategory.time)))
      ..dispatch(const SettingsFacts(time: TimeState(zone: 'Asia/Kolkata', automatic: true, synced: true)));
    h.assertView((v) => !v.rows.any((r) => r.key == 'set_time') && !v.rows.any((r) => r.key == 'time_format'));
    h.dispatch(const SettingsFacts(
      time: TimeState(zone: 'Asia/Kolkata', automatic: false, synced: true),
      timeLocales: [TimeLocale(name: 'en_GB.utf8', timeFormat: '%T', dateFormat: '%d/%m/%y')],
      timeLocale: 'en_GB.utf8',
    ));
    h.assertView((v) => v.rows.any((r) => r.key == 'set_time') && v.rows.any((r) => r.key == 'set_date'));
    h.assertView((v) => v.rows.firstWhere((r) => r.key == 'time_format').value == '13:05:00 · 14/10/26');
  });

  test('a battery is a Power row only where one exists', () {
    final h = StoreHarness(SettingsModel())..dispatch(const SettingsGo(open: Change(SettingsCategory.power)));
    h.assertView((v) => !v.categories.any((c) => c.category == SettingsCategory.power));
    h.dispatch(const SettingsFacts(battery: Change(Battery(name: 'BAT0', percent: 41, charging: true))));
    h.assertView((v) => v.rows.firstWhere((r) => r.key == 'battery').value == '41 %, charging');
    h.assertView((v) => v.categories.firstWhere((c) => c.category == SettingsCategory.power).summary == '41 %');
  });

  test('Battery use and Why it is awake: offered where vrxhost estimates (plan 0012 D12)', () {
    final model = SettingsModel();
    final h = StoreHarness(model);
    h.assertView((v) => v.categories.every((c) => c.category != SettingsCategory.power),
        because: 'off-device, with no power off and no battery, there is no Power');
    h.dispatch(const SettingsFacts(energyAvailable: true));
    h.assertView((v) => v.categories.any((c) => c.category == SettingsCategory.power), because: 'the estimate is a Power row');
    h.dispatch(const SettingsGo(open: Change(SettingsCategory.power)));
    h.assertView((v) => v.rows.map((r) => r.key).toList().join(',') == 'battery_use,why_awake',
        because: 'both open their screens; nothing else on this device');
    h
      ..dispatch(const SettingsGo(showingUse: true))
      ..dispatch(const SettingsGo(pickingZone: true, settingTime: SettingTime.date));
    h.verify(
      fresh: SettingsModel.new,
      probes: const [
        SettingsAction.back,
        SettingsGo(renaming: true),
        SettingsGo(editingSetting: Change(('clock', 'chime'))),
        SettingsFacts(error: 'x'),
      ],
      routes: const ['time', 'nope'],
      openAt: (r) => r == 'time'
          ? const SettingsGo(open: Change(SettingsCategory.time), pickingZone: false, settingTime: SettingTime.none)
          : null,
    );
  });
}
