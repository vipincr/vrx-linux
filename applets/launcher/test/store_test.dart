import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

import 'package:launcher_applet/state.dart';

void main() {
  test('the boot action lists the registry, position-ordered', () {
    final harness = StoreHarness(LauncherModel());
    harness.assertView(
      (v) => v.tiles.length == 2 && v.tiles.first.id == 'clock',
      because: 'clock (position 3) sorts before settings (position 4)',
    );
  });

  test('a registry change re-renders the grid', () {
    final model = LauncherModel();
    final harness = StoreHarness(model);
    model.replaceRegistry({
      'clock': const Tile(id: 'clock', name: 'Clock', position: 1),
      'settings': const Tile(id: 'settings', name: 'Settings', position: 2),
      'notes': const Tile(id: 'notes', name: 'Notes', position: 3),
    });
    harness.dispatch(LauncherAction.registryChanged);
    harness.assertView((v) => v.tiles.length == 3);
  });

  test('a query filters the tiles by what a person reads', () {
    final model = LauncherModel();
    model.search('set');
    final harness = StoreHarness(model);
    harness.dispatch(LauncherAction.searchChanged);
    harness.assertView(
      (v) => v.tiles.length == 1 && v.tiles.single.id == 'settings',
    );
  });

  test('an empty registry shows no apps, never an error', () {
    final model = LauncherModel(registry: const {});
    final harness = StoreHarness(model);
    harness.assertView((v) => v.tiles.isEmpty);
  });

  // plan 0011 D16: installs with consent, worded for what happens
  test('offers: installable and refused ones show; older and same do not', () {
    final model = LauncherModel()
      ..offers = const [
        AppOffer(file: 'a.raw', id: 'a', name: 'A', version: '1', build: 'x', kind: 'install'),
        AppOffer(file: 'b.raw', id: 'b', name: 'B', version: '1', build: 'y', kind: 'same', installed: '1'),
        AppOffer(file: 'c.raw', id: 'c', name: 'C', version: '0.9', build: 'z', kind: 'older', installed: '1'),
        AppOffer(file: 'd.raw', id: 'd', name: 'D', version: '1', build: 'w', kind: 'install', problem: 'release'),
      ];
    final h = StoreHarness(model);
    h.dispatch(LauncherAction.offersChanged);
    h.assertView((v) => v.offers.map((o) => o.id).join() == 'ad');
  });

  test('consent names the act and says the app is unsigned', () {
    const base = AppOffer(file: 'n.raw', id: 'n', name: 'Notes', version: '1.3.0', build: 'x', kind: 'install');
    expect(consentFor(base).title, 'Install Notes 1.3.0?');
    expect(consentFor(base).message, contains('not signed'));
    expect(consentFor(const AppOffer(file: 'n.raw', id: 'n', name: 'Notes', version: '1.3.0', build: 'x', kind: 'update')).title,
        'Update Notes to 1.3.0?');
    expect(consentFor(const AppOffer(file: 'n.raw', id: 'n', name: 'Notes', version: '1.2.0', build: 'x', kind: 'replace')).act, 'Replace');
    expect(VrxWords.offerProblem('paths'), contains('outside its own folder'));
  });
}
