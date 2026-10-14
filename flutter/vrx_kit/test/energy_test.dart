import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

void main() {
  test('the ranking reads vrxhost\'s reply; not calibrated has no energy', () {
    final r = EnergyReport.fromJson({
      'calibrated': true,
      'measured': '2026-10-14 with fnb58',
      'hours': 24,
      'rows': [
        {'key': 'system:floor', 'name': 'Idle floor', 'kind': 'system', 'mj': 90000, 'cpu_ms': 0, 'gpu_ms': 0, 'wakeups': 0, 'front_s': 0, 'over': false},
        {'key': 'web', 'name': 'Web requests', 'kind': 'applet', 'mj': 12000, 'cpu_ms': 3400, 'gpu_ms': 600, 'wakeups': 70, 'front_s': 30, 'over': true},
      ],
    });
    expect(r.calibrated, isTrue);
    expect(r.totalMillijoules, 102000);
    expect(r.rows.last.system, isFalse);
    expect(r.rows.last.over, isTrue);
    expect(r.rows.last.busyMs, 4000);
    final u = EnergyReport.fromJson({
      'calibrated': false,
      'hours': 24,
      'rows': [
        {'key': 'web', 'name': 'Web requests', 'kind': 'applet', 'cpu_ms': 3400, 'gpu_ms': 0, 'wakeups': 0, 'front_s': 0, 'over': false},
      ],
    });
    expect(u.totalMillijoules, isNull);
    expect(u.rows.single.millijoules, isNull);
  });

  test('a power alert speaks in a sentence and knows when it is answered', () {
    final a = PowerAlert.fromJson({'applet': 'web', 'name': 'Web requests', 'budget': 'background', 'percent': 41.5, 'since': 1, 'answer': ''});
    expect(a.open, isTrue);
    expect(a.sentence, 'Web requests is using a lot of power in the background.');
    expect(PowerAlert.fromJson({'name': 'Clock', 'budget': 'front', 'answer': 'later'}).open, isFalse);
    expect(PowerAlert.fromJson({'name': 'Clock', 'budget': 'front'}).sentence, 'Clock is using a lot of power.');
  });

  test('amounts read as a person compares them', () {
    expect(energyLabel(1200), '1.2 J');
    expect(energyLabel(340000), '340 J');
    expect(energyLabel(2400000), '2.4 kJ');
    expect(energyLabel(5400000), '1.5 Wh');
    expect(busyLabel(12000), '12 s');
    expect(busyLabel(240000), '4 min');
    expect(busyLabel(4800000), '1 h 20 min');
  });
}
