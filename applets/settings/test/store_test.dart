import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

import 'package:settings_applet/state.dart';

void main() {
  test('the boot action lists every declared setting', () {
    final harness = StoreHarness(SettingsModel());
    harness.assertView(
      (v) => v.rows.length == 2 && v.openCategory == null,
      because: 'two declared settings, no category open',
    );
  });

  test('a value change is reflected in its row', () {
    final model = SettingsModel();
    final harness = StoreHarness(model);
    model.changeValue('clock_format', '12h');
    harness.dispatch(SettingsAction.changed);
    final row =
        harness.view.rows.firstWhere((r) => r.key == 'clock_format');
    expect(row.value, '12h');
  });

  test('an unknown key is refused, not invented', () {
    final model = SettingsModel();
    model.changeValue('no_such_setting', 'x');
    final harness = StoreHarness(model);
    expect(
      harness.view.rows.where((r) => r.key == 'no_such_setting'),
      isEmpty,
    );
  });

  test('opening a category filters the rows', () {
    final model = SettingsModel();
    model.openCategory('Clock');
    final harness = StoreHarness(model);
    harness.dispatch(SettingsAction.categoryOpened);
    harness.assertView(
      (v) => v.rows.length == 1 && v.rows.single.category == 'Clock',
    );
  });
}
