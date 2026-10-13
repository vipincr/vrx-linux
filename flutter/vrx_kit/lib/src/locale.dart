/// The system's locale for time (plan 0011 D7), Linux first: the
/// installed locales are glibc's (`locale -a`), each one's time format is
/// what glibc says for it (`locale t_fmt d_fmt` under that locale), and
/// the choice is systemd-localed's (`SetLocale`, written to
/// /etc/locale.conf). flutter-vrx reads LC_TIME from that file and tells
/// every applet through Flutter's alwaysUse24HourFormat. Changing it needs
/// the `locale` grant.
library;

import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';

import 'system.dart';

/// One installed locale and how it writes the time.
class TimeLocale {
  const TimeLocale({required this.name, required this.timeFormat, required this.dateFormat});

  /// glibc's name (`en_GB.utf8`).
  final String name;

  /// strftime formats (`%H:%M:%S`, `%d/%m/%y`).
  final String timeFormat;
  final String dateFormat;

  /// 24-hour unless the format names an AM/PM hour.
  bool get h24 => !(timeFormat.contains('%p') || timeFormat.contains('%I') || timeFormat.contains('%r') || timeFormat.contains('%l'));

  /// How it writes 13:05, and 14 October 2026, for a person to choose by.
  String get timeExample => _strftime(timeFormat, 13, 5, 0);
  String get dateExample => _strftime(dateFormat, 13, 5, 0);
  String get example => '$timeExample · $dateExample';
}

/// strftime for the fields a time or date format uses here.
String _strftime(String format, int hour, int minute, int second) {
  final pm = hour >= 12;
  final h12 = hour % 12 == 0 ? 12 : hour % 12;
  String two(int n) => n.toString().padLeft(2, '0');
  final out = StringBuffer();
  for (var i = 0; i < format.length; i++) {
    final c = format[i];
    if (c != '%' || i + 1 >= format.length) {
      out.write(c);
      continue;
    }
    final f = format[++i];
    out.write(switch (f) {
      'H' => two(hour),
      'k' => '$hour',
      'I' => two(h12),
      'l' => '$h12',
      'M' => two(minute),
      'S' => two(second),
      'p' => pm ? 'PM' : 'AM',
      'P' => pm ? 'pm' : 'am',
      'r' => '${two(h12)}:${two(minute)}:${two(second)} ${pm ? 'PM' : 'AM'}',
      'R' => '${two(hour)}:${two(minute)}',
      'T' => '${two(hour)}:${two(minute)}:${two(second)}',
      'd' => '14',
      'e' => '14',
      'm' => '10',
      'y' => '26',
      'Y' => '2026',
      'b' || 'h' => 'Oct',
      'B' => 'October',
      'a' => 'Wed',
      'A' => 'Wednesday',
      'D' => '10/14/26',
      'F' => '2026-10-14',
      _ => '%$f',
    });
  }
  return out.toString();
}

abstract class LocaleService {
  /// The installed locales a time format can come from (C and POSIX
  /// excluded: they name no place).
  Future<List<TimeLocale>> timeLocales();

  /// The locale LC_TIME is now ('' when unset: the system's default).
  Future<String> timeLocale();

  /// Make [name] the system's time locale.
  Future<void> setTimeLocale(String name);
}

class LocaledLocaleService implements LocaleService {
  LocaledLocaleService(DBusClient bus)
      : _object = DBusRemoteObject(bus, name: 'org.freedesktop.locale1', path: DBusObjectPath('/org/freedesktop/locale1'));

  static const _iface = 'org.freedesktop.locale1';
  final DBusRemoteObject _object;

  @override
  Future<List<TimeLocale>> timeLocales() async {
    final list = await Process.run('locale', ['-a']);
    if (list.exitCode != 0) return const [];
    final names = '${list.stdout}'.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty && l != 'C' && l != 'POSIX' && !l.startsWith('C.'));
    final out = <TimeLocale>[];
    for (final name in names) {
      final r = await Process.run('locale', ['t_fmt', 'd_fmt'], environment: {'LC_ALL': name});
      final lines = '${r.stdout}'.split('\n');
      if (r.exitCode != 0 || lines.length < 2) continue;
      out.add(TimeLocale(name: name, timeFormat: lines[0].trim(), dateFormat: lines[1].trim()));
    }
    return out;
  }

  Future<List<String>> _settings() async {
    final v = await _object.getProperty(_iface, 'Locale', signature: DBusSignature('as'));
    return v.asStringArray().toList();
  }

  @override
  Future<String> timeLocale() async {
    final all = await _settings();
    String of(String key) => all.firstWhere((e) => e.startsWith('$key='), orElse: () => '').split('=').skip(1).join('=');
    final t = of('LC_TIME');
    return t.isNotEmpty ? t : of('LANG');
  }

  @override
  Future<void> setTimeLocale(String name) async {
    final all = [for (final e in await _settings()) if (!e.startsWith('LC_TIME=')) e, 'LC_TIME=$name'];
    try {
      await _object.callMethod(_iface, 'SetLocale', [DBusArray.string(all), const DBusBoolean(false)],
          replySignature: DBusSignature(''));
    } on DBusMethodResponseException catch (err) {
      throw SystemError(err.errorName, err.response.values.isEmpty ? '' : '${err.response.values.first.toNative()}');
    }
  }
}
