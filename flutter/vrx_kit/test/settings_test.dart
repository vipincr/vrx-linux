import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

void main() {
  test('settings files parse, write whole, and a watcher sees a write', () async {
    expect(parseSettings('# c\nclock_format=12h\n\nbad line\nk = v \nclock_format=24h\n'), {'clock_format': '24h', 'k': 'v'});
    expect(settingText(true), 'true');
    expect(settingText(12), '12');
    final dir = await Directory.systemTemp.createTemp('vrx-settings');
    addTearDown(() => dir.delete(recursive: true));
    final s = AppletSettings(dir: dir.path);
    expect(await s.read('clock'), isEmpty);
    await s.set('clock', 'clock_format', '12h');
    await s.set('clock', 'other', 'x');
    expect(await s.read('clock'), {'clock_format': '12h', 'other': 'x'});
    final seen = <Map<String, String>>[];
    final sub = s.watch('clock').listen(seen.add);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await s.set('clock', 'clock_format', '24h');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await sub.cancel();
    expect(seen.first['clock_format'], '12h');
    expect(seen.last['clock_format'], '24h');
  });
}
