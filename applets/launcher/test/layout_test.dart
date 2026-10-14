import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_check/vrx_check.dart';
import 'package:vrx_kit/vrx_kit.dart';

import 'package:launcher_applet/main.dart';
import 'package:launcher_applet/state.dart';

/// Home holds on every display vrx drives (vrx_check), with a full grid.
void main() {
  Map<String, Tile> tiles() => {
        for (final (i, t) in [
          ('web', 'Web requests', 'http'),
          ('long', 'A tile with a name far too long for two lines', 'apps'),
          ('clock', 'Clock', 'schedule'),
          ('settings', 'Settings', 'settings'),
          ('terminal', 'Terminal', 'terminal'),
          ('wifi', 'Wi-Fi', 'wifi'),
          ('docs', 'Licences', 'gavel'),
          ('recorder', 'Recorder', 'mic'),
          ('scripts', 'Scripts', 'code'),
        ].indexed)
          t.$1: Tile(id: t.$1, name: t.$2, position: i, icon: t.$3),
      };
  LauncherApplet home() => LauncherApplet(startingFacts: [LauncherRegistry(tiles())]);
  // every applet in the repo as Home shows it: its manifest's name and
  // icon on a tile, so a new applet's name is measured with no new test
  LauncherApplet repoHome() => LauncherApplet(startingFacts: [
        LauncherRegistry({
          for (final m in repoManifests())
            if (m.tile) m.id: Tile(id: m.id, name: m.name, position: m.position, icon: m.icon),
        }),
      ]);
  // offers after the tiles: one to install, an update, one refused
  LauncherApplet offered() => LauncherApplet(startingFacts: [
        LauncherRegistry(tiles()),
        const LauncherOffers([
          AppOffer(file: 'notes.raw', id: 'notes', name: 'Notes', version: '1.2.0', build: 'a', kind: 'install'),
          AppOffer(file: 'tasks.raw', id: 'tasks', name: 'Tasks for the week', version: '2.0.0', build: 'b', kind: 'update', installed: '1.9.0'),
          AppOffer(file: 'bad.raw', id: 'bad', name: 'Bad', version: '1.0.0', build: 'c', kind: 'install', problem: 'paths'),
        ]),
      ]);
  for (final display in allDisplays) {
    testWidgets('home with offers on ${display.name}', (tester) async {
      await expectCleanLayout(tester, offered(), display: display);
    });
    testWidgets('home with every repo applet on ${display.name}', (tester) async {
      await expectCleanLayout(tester, repoHome(), display: display);
    });
    testWidgets('home on ${display.name}', (tester) async {
      await expectCleanLayout(tester, home(), display: display);
    });
    // the owner (2026-10-13): the top bar was a third of the screen.
    // The apps are Home: the status row takes at most a fifth, and at
    // least three columns and two whole rows of tiles show
    testWidgets('home proportions on ${display.name}', (tester) async {
      await shotLayout(tester, home(), display: display);
      final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
      final grid = tester.getRect(find.byType(GridView));
      expect(grid.top, lessThanOrEqualTo(screen.height * 0.2), reason: 'status row over a fifth of the screen');
      final tiles = find.byWidgetPredicate((w) => w.runtimeType.toString() == '_Tile').evaluate().toList();
      final rects = [for (final e in tiles) tester.getRect(find.byWidget(e.widget))];
      final tops = {for (final r in rects) r.top.round()}.toList()..sort();
      final columns = rects.where((r) => r.top.round() == tops.first).length;
      expect(columns, greaterThanOrEqualTo(3), reason: 'fewer than three columns');
      final whole = rects.where((r) => r.bottom <= screen.height + 0.5).map((r) => r.top.round()).toSet();
      expect(whole.length, greaterThanOrEqualTo(2), reason: 'fewer than two whole rows');
    });
  }
}
