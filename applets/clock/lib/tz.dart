/// Time zones from the device's own tzdata (/usr/share/zoneinfo), the
/// files timedated sets /etc/localtime from, so the clock and the system
/// agree on every offset.
///
/// Dart's local time cannot follow a zone change: glibc reads the zone
/// once per process. Every local time the clock shows is therefore UTC
/// plus [Zone.offsetAt], for the home zone and for the world cities.
///
/// A TZif file lists transitions; past the last one its footer, a POSIX
/// TZ string ("CET-1CEST,M3.5.0,M10.5.0/3"), gives the rule. Slim tzdata
/// stops listing early, so the footer decides most of today's offsets.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// One zone's offsets over time.
class Zone {
  Zone(this.name, this._times, this._offsets, this._initial, this._rule);

  /// A zone that is always [offsetSeconds] east of UTC (UTC itself, or a
  /// fallback when a zone's file cannot be read).
  Zone.fixed(this.name, int offsetSeconds)
      : _times = const [],
        _offsets = const [],
        _initial = offsetSeconds,
        _rule = null;

  final String name;
  final List<int> _times; // transition instants, UTC seconds, ascending
  final List<int> _offsets; // the offset from each transition on
  final int _initial; // before the first transition
  final PosixRule? _rule;

  /// Seconds east of UTC at [utcSeconds].
  int offsetAt(int utcSeconds) {
    final rule = _rule;
    if (_times.isEmpty || utcSeconds < _times.first) {
      return _times.isEmpty && rule != null ? rule.offsetAt(utcSeconds) : _initial;
    }
    if (utcSeconds >= _times.last && rule != null) return rule.offsetAt(utcSeconds);
    var lo = 0, hi = _times.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_times[mid] <= utcSeconds) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return _offsets[lo];
  }

  /// The wall time at [utcSeconds], as a UTC-flagged DateTime whose
  /// fields read as local.
  DateTime local(int utcSeconds) =>
      DateTime.fromMillisecondsSinceEpoch((utcSeconds + offsetAt(utcSeconds)) * 1000, isUtc: true);

  /// The UTC instant a wall time names. In a gap (clocks forward) it
  /// lands after it; in an overlap, on the first.
  int utcOf(DateTime wall) {
    final w = wall.millisecondsSinceEpoch ~/ 1000;
    final first = w - offsetAt(w);
    return w - offsetAt(first);
  }
}

/// Read [name]'s TZif file; UTC (offset 0) if it is missing or bad.
Future<Zone> loadZone(String name, {String root = '/usr/share/zoneinfo'}) async {
  if (name.isEmpty || name.contains('..')) return Zone.fixed(name, 0);
  try {
    return parseTzif(name, await File('$root/$name').readAsBytes());
  } on Object {
    return Zone.fixed(name, 0);
  }
}

/// Parse a TZif file (RFC 8536), preferring its 64-bit section.
Zone parseTzif(String name, Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  if (bytes.length < 44 || ascii.decode(bytes.sublist(0, 4)) != 'TZif') {
    throw const FormatException('not a TZif file');
  }
  final version = bytes[4];
  var at = 0;
  ({int isut, int isstd, int leap, int time, int type, int char}) header(int base) => (
        isut: data.getUint32(base + 20),
        isstd: data.getUint32(base + 24),
        leap: data.getUint32(base + 28),
        time: data.getUint32(base + 32),
        type: data.getUint32(base + 36),
        char: data.getUint32(base + 40),
      );
  var h = header(0);
  var timeSize = 4;
  if (version >= 0x32) {
    // skip the 32-bit block to the 64-bit header
    at = 44 + h.time * 4 + h.time + h.type * 6 + h.char + h.leap * 8 + h.isstd + h.isut;
    h = header(at);
    timeSize = 8;
  }
  var p = at + 44;
  final times = <int>[];
  for (var i = 0; i < h.time; i++, p += timeSize) {
    times.add(timeSize == 8 ? data.getInt64(p) : data.getInt32(p));
  }
  final index = bytes.sublist(p, p + h.time);
  p += h.time;
  final types = <({int utoff, bool dst})>[];
  for (var i = 0; i < h.type; i++, p += 6) {
    types.add((utoff: data.getInt32(p), dst: bytes[p + 4] != 0));
  }
  p += h.char + h.leap * (timeSize + 4) + h.isstd + h.isut;
  PosixRule? rule;
  if (timeSize == 8 && p < bytes.length && bytes[p] == 0x0a) {
    final end = bytes.indexOf(0x0a, p + 1);
    if (end > p + 1) rule = PosixRule.tryParse(ascii.decode(bytes.sublist(p + 1, end)));
  }
  // before the first transition: the first standard-time type (RFC 8536)
  final initial = types.firstWhere((t) => !t.dst, orElse: () => types.isEmpty ? (utoff: 0, dst: false) : types.first);
  return Zone(name, times, [for (final i in index) types[i].utoff], initial.utoff, rule);
}

/// A POSIX TZ rule: a standard offset, and optionally a daylight offset
/// with the dates it starts and ends.
class PosixRule {
  PosixRule._(this.std, this.dst, this._start, this._end);

  /// Seconds east of UTC in standard and daylight time.
  final int std;
  final int? dst;
  final _When? _start, _end;

  static PosixRule? tryParse(String s) {
    try {
      return _Parser(s).rule();
    } on FormatException {
      return null;
    }
  }

  int offsetAt(int utc) {
    final daylight = dst;
    final start = _start, end = _end;
    if (daylight == null || start == null || end == null) return std;
    // the year as standard time reads it
    final year = DateTime.fromMillisecondsSinceEpoch((utc + std) * 1000, isUtc: true).year;
    // a start is written in standard time, an end in daylight time
    final on = start.localSeconds(year) - std;
    final off = end.localSeconds(year) - daylight;
    final inDst = on < off ? (utc >= on && utc < off) : !(utc >= off && utc < on);
    return inDst ? daylight : std;
  }
}

/// A rule date: Mm.w.d, Jn or n, and the time of day it applies.
class _When {
  _When(this.kind, this.a, this.b, this.c, this.time);

  final String kind; // 'M', 'J' or 'n'
  final int a, b, c; // M: month, week, weekday; J/n: the day in a
  final int time; // seconds after local midnight (may be negative or > 24h)

  /// Seconds since the epoch, as local wall time, in [year].
  int localSeconds(int year) {
    final jan1 = _days(year, 1, 1);
    int day;
    switch (kind) {
      case 'M':
        final first = _days(year, a, 1);
        final weekday = (first + 4) % 7; // 1970-01-01 was a Thursday
        day = first + (c - weekday + 7) % 7 + 7 * (b - 1);
        final next = a == 12 ? _days(year + 1, 1, 1) : _days(year, a + 1, 1);
        while (day >= next) {
          day -= 7; // week 5 is the last such weekday
        }
      case 'J':
        final leap = _isLeap(year);
        day = jan1 + a - 1 + (leap && a >= 60 ? 1 : 0);
      default:
        day = jan1 + a;
    }
    return day * 86400 + time;
  }
}

bool _isLeap(int y) => y % 4 == 0 && (y % 100 != 0 || y % 400 == 0);

/// Days since 1970-01-01 of a civil date (Howard Hinnant's algorithm).
int _days(int y, int m, int d) {
  y -= m <= 2 ? 1 : 0;
  final era = (y >= 0 ? y : y - 399) ~/ 400;
  final yoe = y - era * 400;
  final doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) ~/ 5 + d - 1;
  final doe = yoe * 365 + yoe ~/ 4 - yoe ~/ 100 + doy;
  return era * 146097 + doe - 719468;
}

class _Parser {
  _Parser(this.s);

  final String s;
  int i = 0;

  bool get done => i >= s.length;
  String get peek => done ? '' : s[i];

  PosixRule rule() {
    _name();
    final std = -_offset();
    if (done) return PosixRule._(std, null, null, null);
    _name();
    var dst = std + 3600;
    if (!done && peek != ',') dst = -_offset();
    if (done) return PosixRule._(std, dst, null, null);
    _expect(',');
    final start = _when();
    _expect(',');
    final end = _when();
    if (!done) throw const FormatException('trailing text');
    return PosixRule._(std, dst, start, end);
  }

  void _name() {
    if (peek == '<') {
      final close = s.indexOf('>', i);
      if (close < 0) throw const FormatException('unclosed name');
      i = close + 1;
      return;
    }
    final start = i;
    while (!done && RegExp('[A-Za-z]').hasMatch(peek)) {
      i++;
    }
    if (i - start < 3) throw const FormatException('short name');
  }

  /// [+-]hh[:mm[:ss]] in seconds, as written (west positive).
  int _offset() {
    var sign = 1;
    if (peek == '+' || peek == '-') {
      sign = peek == '-' ? -1 : 1;
      i++;
    }
    return sign * _hms();
  }

  int _hms() {
    var total = _number() * 3600;
    if (peek == ':') {
      i++;
      total += _number() * 60;
      if (peek == ':') {
        i++;
        total += _number();
      }
    }
    return total;
  }

  int _number() {
    final start = i;
    while (!done && '0123456789'.contains(peek)) {
      i++;
    }
    if (i == start) throw const FormatException('number expected');
    return int.parse(s.substring(start, i));
  }

  _When _when() {
    String kind;
    int a, b = 0, c = 0;
    if (peek == 'M') {
      i++;
      kind = 'M';
      a = _number();
      _expect('.');
      b = _number();
      _expect('.');
      c = _number();
    } else if (peek == 'J') {
      i++;
      kind = 'J';
      a = _number();
    } else {
      kind = 'n';
      a = _number();
    }
    var time = 7200;
    if (peek == '/') {
      i++;
      var sign = 1;
      if (peek == '-' || peek == '+') {
        sign = peek == '-' ? -1 : 1;
        i++;
      }
      time = sign * _hms();
    }
    return _When(kind, a, b, c, time);
  }

  void _expect(String c) {
    if (peek != c) throw FormatException('expected $c');
    i++;
  }
}
