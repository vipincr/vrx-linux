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
}
