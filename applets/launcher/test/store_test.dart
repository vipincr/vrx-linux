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
    final harness = StoreHarness(LauncherModel())
      ..dispatch(const LauncherRegistry({
        'clock': Tile(id: 'clock', name: 'Clock', position: 1),
        'settings': Tile(id: 'settings', name: 'Settings', position: 2),
        'notes': Tile(id: 'notes', name: 'Notes', position: 3),
      }));
    harness.assertView((v) => v.tiles.length == 3);
    harness
      ..dispatch(const LauncherError(Change('refused')))
      ..dispatch(const LauncherSearch('no'));
    harness.verify(
      fresh: LauncherModel.new,
      probes: const [LauncherAction.appFinished, LauncherError(Change(null)), LauncherSearch('')],
    );
  });

  test('a query filters the tiles by what a person reads', () {
    final harness = StoreHarness(LauncherModel())..dispatch(const LauncherSearch('set'));
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
    final model = LauncherModel();
    final h = StoreHarness(model)
      ..dispatch(const LauncherOffers([
        AppOffer(file: 'a.raw', id: 'a', name: 'A', version: '1', build: 'x', kind: 'install'),
        AppOffer(file: 'b.raw', id: 'b', name: 'B', version: '1', build: 'y', kind: 'same', installed: '1'),
        AppOffer(file: 'c.raw', id: 'c', name: 'C', version: '0.9', build: 'z', kind: 'older', installed: '1'),
        AppOffer(file: 'd.raw', id: 'd', name: 'D', version: '1', build: 'w', kind: 'install', problem: 'release'),
      ]));
    h.assertView((v) => v.offers.map((o) => o.id).join() == 'ad');
  });

  test('consent names the act and says whether anything proves who made it', () {
    const base = AppOffer(file: 'n.raw', id: 'n', name: 'Notes', version: '1.3.0', build: 'x', kind: 'install');
    expect(consentFor(base).title, 'Install Notes 1.3.0?');
    expect(consentFor(base).message, contains('without checking a signature'));
    const signed =
        AppOffer(file: 'n.raw', id: 'n', name: 'Notes', version: '1.3.0', build: 'x', kind: 'install', signed: true);
    expect(consentFor(signed).message, contains('signed by a key this device trusts'));
    expect(consentFor(signed).message, isNot(contains('without checking')));
    expect(AppOffer.fromJson({'file': 'n.raw', 'signed': true}).signed, isTrue);
    expect(AppOffer.fromJson({'file': 'n.raw'}).signed, isFalse);
    expect(VrxWords.offerProblem('unsigned'), contains('only signed apps'));
    expect(VrxWords.offerProblem('untrusted'), contains('does not trust'));
    expect(consentFor(const AppOffer(file: 'n.raw', id: 'n', name: 'Notes', version: '1.3.0', build: 'x', kind: 'update')).title,
        'Update Notes to 1.3.0?');
    expect(consentFor(const AppOffer(file: 'n.raw', id: 'n', name: 'Notes', version: '1.2.0', build: 'x', kind: 'replace')).act, 'Replace');
    expect(VrxWords.offerProblem('paths'), contains('outside its own folder'));
  });
}
