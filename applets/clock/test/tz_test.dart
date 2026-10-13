import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:clock_applet/tz.dart';

int utc(int y, int mo, int d, [int h = 0, int mi = 0, int s = 0]) =>
    DateTime.utc(y, mo, d, h, mi, s).millisecondsSinceEpoch ~/ 1000;

void main() {
  test('a northern rule switches on the last Sundays of March and October', () {
    final cet = PosixRule.tryParse('CET-1CEST,M3.5.0,M10.5.0/3')!;
    expect(cet.offsetAt(utc(2026, 1, 15)), 3600);
    // 2026-03-29 02:00 CET is 01:00 UTC
    expect(cet.offsetAt(utc(2026, 3, 29, 0, 59, 59)), 3600);
    expect(cet.offsetAt(utc(2026, 3, 29, 1)), 7200);
    // 2026-10-25 03:00 CEST is 01:00 UTC
    expect(cet.offsetAt(utc(2026, 10, 25, 0, 59, 59)), 7200);
    expect(cet.offsetAt(utc(2026, 10, 25, 1)), 3600);
  });

  test('a southern rule is daylight across the new year', () {
    final sydney = PosixRule.tryParse('AEST-10AEDT,M10.1.0,M4.1.0/3')!;
    expect(sydney.offsetAt(utc(2026, 1, 10)), 39600);
    expect(sydney.offsetAt(utc(2026, 7, 10)), 36000);
    // 2026-10-04 02:00 AEST is 2026-10-03 16:00 UTC
    expect(sydney.offsetAt(utc(2026, 10, 3, 15, 59)), 36000);
    expect(sydney.offsetAt(utc(2026, 10, 3, 16)), 39600);
  });

  test('fixed and quoted zones, and the second Sunday of March', () {
    expect(PosixRule.tryParse('IST-5:30')!.offsetAt(utc(2026, 6, 1)), 19800);
    expect(PosixRule.tryParse('<+0545>-5:45')!.offsetAt(utc(2026, 6, 1)), 20700);
    final ny = PosixRule.tryParse('EST5EDT,M3.2.0,M11.1.0')!;
    expect(ny.offsetAt(utc(2026, 3, 8, 6, 59)), -18000);
    expect(ny.offsetAt(utc(2026, 3, 8, 7)), -14400);
    expect(PosixRule.tryParse('nonsense'), isNull);
  });

  test('a TZif file: transitions, then its footer rule', () {
    final zone = parseTzif('Test/Zone', _tzif(
      transitions: [utc(2000, 1, 1)],
      types: [(utoff: 1800, dst: false), (utoff: 3600, dst: false)],
      indices: [1],
      footer: 'CET-1CEST,M3.5.0,M10.5.0/3',
    ));
    expect(zone.offsetAt(utc(1999, 6, 1)), 1800, reason: 'before the first transition');
    expect(zone.offsetAt(utc(2026, 1, 15)), 3600, reason: 'past the last: the footer, standard');
    expect(zone.offsetAt(utc(2026, 7, 15)), 7200, reason: 'past the last: the footer, daylight');
    final wall = DateTime.utc(2026, 7, 15, 9);
    expect(zone.utcOf(wall), utc(2026, 7, 15, 7));
    expect(zone.local(utc(2026, 7, 15, 7)), wall);
  });
}

/// A version-2 TZif file with an empty 32-bit block.
Uint8List _tzif({
  required List<int> transitions,
  required List<({int utoff, bool dst})> types,
  required List<int> indices,
  required String footer,
}) {
  final b = BytesBuilder();
  void header(int time, int type) {
    b.add(ascii.encode('TZif2'));
    b.add(List.filled(15, 0));
    final counts = ByteData(24);
    counts.setUint32(12, time);
    counts.setUint32(16, type);
    counts.setUint32(20, 4); // charcnt
    b.add(counts.buffer.asUint8List());
  }

  // v1: no transitions, one type, four chars
  header(0, 1);
  b.add([0, 0, 0, 0, 0, 0]);
  b.add(ascii.encode('UTC\u0000'));
  header(transitions.length, types.length);
  for (final t in transitions) {
    final d = ByteData(8)..setInt64(0, t);
    b.add(d.buffer.asUint8List());
  }
  b.add(indices);
  for (final t in types) {
    final d = ByteData(6)
      ..setInt32(0, t.utoff)
      ..setUint8(4, t.dst ? 1 : 0);
    b.add(d.buffer.asUint8List());
  }
  b.add(ascii.encode('UTC\u0000'));
  b.add(ascii.encode('\n$footer\n'));
  return b.toBytes();
}
