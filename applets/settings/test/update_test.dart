import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

import 'package:settings_applet/state.dart';

/// Settings > Device > Software update (plan 0016 D11).
void main() {
  // the reduce budget times one action; warm the reducer and the rows in
  // this isolate first (store_test.dart says why)
  setUpAll(() {
    final warm = SettingsModel();
    for (final c in SettingsCategory.values) {
      warm.reduce(const SettingsState(open: null, pickingZone: false), SettingsGo(open: Change(c)));
    }
    warm
      ..reduce(const SettingsState(open: null, pickingZone: false),
          const SettingsFacts(updatesAvailable: true, updateStatus: UpdateStatus(running: '0')))
      ..reduce(const SettingsState(open: null, pickingZone: false), SettingsAction.back);
  });

  const status = UpdateStatus(running: '0.1.0074');
  const offer = UpdateOffer(file: 'vrx-bundle-vrxboard-cm4-0.1.0081.raucb', version: '0.1.0081');

  test('offered only where vrxhost answers for updates; the row says what the last one did', () {
    final model = SettingsModel();
    final h = StoreHarness(model)
      ..dispatch(const SettingsFacts(device: DeviceState(name: 'Kitchen display', hostname: 'kitchen-display', version: '0.1.0074')))
      ..dispatch(const SettingsGo(open: Change(SettingsCategory.device)));
    Iterable<String> keys() => h.view.rows.map((r) => r.key);
    expect(keys(), isNot(contains('software_update')), reason: 'no grant, no RAUC: no row');
    h.dispatch(const SettingsFacts(updatesAvailable: true, updateStatus: status));
    String row() => h.view.rows.firstWhere((r) => r.key == 'software_update').value;
    expect(row(), '0.1.0074');
    h.dispatch(const SettingsFacts(updateStatus: UpdateStatus(running: '0.1.0074', last: UpdateOutcome.fellBack)));
    expect(row(), 'Went back');
    h.dispatch(const SettingsFacts(updateInstalled: '0.1.0081'));
    expect(row(), 'Restart to finish', reason: 'an installed update waits for the restart');
  });

  test('the screen opens empty, fills, installs, and Back leaves it (plan 0013 D2)', () {
    final model = SettingsModel();
    final h = StoreHarness(model)
      ..dispatch(const SettingsFacts(updatesAvailable: true, updateStatus: status))
      ..dispatch(const SettingsGo(open: Change(SettingsCategory.device)))
      ..dispatch(const SettingsFacts(updateOffers: [offer]))
      ..dispatch(const SettingsGo(showingUpdate: true));
    expect(model.updateOffers, isNull, reason: 'opening asks again: no stale offers');
    h
      ..dispatch(const SettingsFacts(updateStatus: status, updateOffers: [offer]))
      ..dispatch(const SettingsFacts(updateInstalling: Change('0.1.0081')));
    expect(model.updateInstalling, '0.1.0081');
    h.dispatch(const SettingsFacts(updateInstalling: Change(null), updateInstalled: '0.1.0081'));
    expect((model.updateInstalling, model.updateInstalled), (null, '0.1.0081'));
    h.dispatch(SettingsAction.back);
    expect((model.showingUpdate, model.open), (false, SettingsCategory.device));
    h
      ..dispatch(const SettingsGo(showingUpdate: true))
      ..verify(
        fresh: SettingsModel.new,
        probes: const [
          SettingsAction.back,
          SettingsGo(showingUpdate: true),
          SettingsFacts(updateOffers: []),
          SettingsFacts(updateInstalling: Change(null)),
          SettingsFacts(error: 'x'),
        ],
      );
  });
}
