import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_check/vrx_check.dart';

import 'package:launcher_applet/main.dart';
import 'package:launcher_applet/state.dart';

/// Home holds on every display vrx drives (vrx_check), with a full grid.
void main() {
  LauncherApplet home() => LauncherApplet()
    ..replaceRegistry({
      for (final (i, t) in [
        ('web', 'Web requests', 'language'),
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
    });
  for (final display in allDisplays) {
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
