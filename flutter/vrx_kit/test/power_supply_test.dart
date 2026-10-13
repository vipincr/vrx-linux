import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

/// plan 0011 D12, D7, D14: the kit reads what Linux says, where it says it.
void main() {
  test('a battery appears where the kernel reports one, and only then', () async {
    final dir = await Directory.systemTemp.createTemp('vrx-ps');
    addTearDown(() => dir.delete(recursive: true));
    final s = PowerSupplyService(root: dir.path);
    expect(await s.battery(), isNull, reason: 'no supplies');
    await Directory('${dir.path}/AC').create();
    await File('${dir.path}/AC/type').writeAsString('Mains\n');
    expect(await s.battery(), isNull, reason: 'mains is not a battery');
    await Directory('${dir.path}/BAT0').create();
    for (final (f, v) in [('type', 'Battery'), ('capacity', '41'), ('status', 'Charging'), ('voltage_now', '3912000')]) {
      await File('${dir.path}/BAT0/$f').writeAsString('$v\n');
    }
    final b = (await s.battery())!;
    expect((b.name, b.percent, b.charging, b.volts), ('BAT0', 41, true, 3.912));
  });

  test("a locale's time format is glibc's, and its example is read from it", () {
    const gb = TimeLocale(name: 'en_GB.utf8', timeFormat: '%T', dateFormat: '%d/%m/%y');
    const us = TimeLocale(name: 'en_US.utf8', timeFormat: '%r', dateFormat: '%m/%d/%Y');
    expect((gb.h24, gb.example), (true, '13:05:00 · 14/10/26'));
    expect((us.h24, us.example), (false, '01:05:00 PM · 10/14/2026'));
  });

  test('the time is written the way the system says', () {
    expect(VrxTimeFormat.hm(13 * 60 + 5, h24: true), '13:05');
    expect(VrxTimeFormat.hm(13 * 60 + 5, h24: false), '1:05 PM');
    expect(VrxTimeFormat.hm(5, h24: false), '12:05 AM');
  });

  test('free memory is MemAvailable', () async {
    final dir = await Directory.systemTemp.createTemp('vrx-mem');
    addTearDown(() => dir.delete(recursive: true));
    await File('${dir.path}/meminfo').writeAsString('MemTotal:  1888256 kB\nMemFree: 100 kB\nMemAvailable:    1491968 kB\n');
    expect((await deviceUsage(meminfo: '${dir.path}/meminfo')).memoryFreeMb, 1457);
  });
}
