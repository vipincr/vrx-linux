import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_check/vrx_check.dart';

import 'package:launcher_applet/main.dart';
import 'package:launcher_applet/state.dart';

/// Pictures for a person, not a gate (the layout test is):
/// `VRX_SHOTS=1 flutter test --update-goldens test/shots_test.dart`.
void main() {
  for (final display in allDisplays) {
    testWidgets('home on ${display.name}', (tester) async {
      final home = LauncherApplet(startingFacts: [
        LauncherRegistry({
          for (final (i, t) in [
            ('web', 'Web requests', 'http'),
            ('clock', 'Clock', 'schedule'),
            ('settings', 'Settings', 'settings'),
            ('terminal', 'Terminal', 'terminal'),
            ('wifi', 'Wi-Fi', 'wifi'),
            ('docs', 'Licences', 'gavel'),
            ('recorder', 'Recorder', 'mic'),
            ('scripts', 'Scripts', 'code'),
          ].indexed)
            t.$1: Tile(id: t.$1, name: t.$2, position: i, icon: t.$3),
        }),
      ]);
      await shotApplet(tester, 'home', home, display: display);
    }, skip: Platform.environment['VRX_SHOTS'] == null);
  }
}
