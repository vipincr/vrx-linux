import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_check/vrx_check.dart';

void main() {
  test('the manifest reader finds names, tiles and declared settings', () {
    final m = parseManifestFacts('''
# a comment
[applet]
id = "clock"                   # id, with a comment
name = "Clock"
[applet.display]
icon = "schedule"
tile = true
position = 3
[[applet.settings]]
key = "clock_format"
label = "Time format"
type = "enum"
default = "24h"
options = ["24h", "12h"]
''');
    expect([m.id, m.name, m.icon, m.tile, m.position], ['clock', 'Clock', 'schedule', true, 3]);
    expect(m.settings.single.options, ['24h', '12h']);
    expect(repoManifests().map((m) => m.id), containsAll(['clock', 'settings', 'launcher']));
  });
}
