import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_check/vrx_check.dart';

import 'package:launcher_applet/main.dart';
import 'package:launcher_applet/state.dart';

/// Home holds on every display vrx drives (vrx_check), with a full grid.
void main() {
  LauncherApplet home() => LauncherApplet()
    ..replaceRegistry({
      for (final (i, t) in [
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
  }
}
