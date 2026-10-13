import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

import 'package:settings_applet/state.dart';

void main() {
  test('a device offers only what it has (plan 0008 D12)', () {
    final model = SettingsModel();
    final harness = StoreHarness(model);
    // no backlight, no power grant: no Display, no Power
    harness.assertView((v) => v.categories.map((c) => c.category).toList().toString() ==
        [SettingsCategory.time, SettingsCategory.network, SettingsCategory.device].toString());
    model
      ..lightLevels = 2
      ..light = true
      ..canPowerOff = true;
    harness.dispatch(SettingsAction.factsChanged);
    harness.assertView((v) => v.categories.first.category == SettingsCategory.display &&
        v.categories.first.summary == 'Light on' &&
        v.categories.any((c) => c.category == SettingsCategory.power));
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
    expect(keys, ['name', 'model', 'version', 'memory', 'licences', 'setup']);
    expect(harness.view.rows.firstWhere((r) => r.key == 'memory').value, '1.8 GB');
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
}
