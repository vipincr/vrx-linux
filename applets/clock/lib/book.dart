/// What the clock keeps: alarms, world cities, a running timer and a
/// snooze. The clock is resident (alive from boot, never evicted), so it
/// is the schedule's one owner: it fires alarms whether or not anyone
/// opened it, and keeps them in its state directory (/var/lib/vrx/clock,
/// on /data), so they outlive a restart and an update.
library;

import 'dart:convert';
import 'dart:io';

import 'package:vrx_kit/vrx_kit.dart';

import 'tz.dart';

/// Limits, as evrx-rt's clock holds them: what one screen lists.
const worldMax = 6;
const alarmsMax = 8;

/// Day bits, Sunday first; 0 is a one-off alarm.
const daySun = 1 << 0;
const daySat = 1 << 6;
const daysAll = 0x7f;
const daysWeek = 0x3e;
const daysWeekend = daySat | daySun;

/// An alarm nobody answers stops after this; a snooze is nine minutes.
const ringSeconds = 30;
const snoozeMinutes = 9;

/// An alarm missed by less than this (the clock restarted across its
/// minute) still rings; one missed by more (the device was off) does not.
const lateSeconds = 600;

class Alarm {
  const Alarm({required this.minutes, this.days = 0, this.enabled = true, this.snooze = true, this.label = ''});

  factory Alarm.fromJson(Map<String, dynamic> j) => Alarm(
        minutes: ((j['minutes'] as num?)?.toInt() ?? 420).clamp(0, 1439),
        days: ((j['days'] as num?)?.toInt() ?? 0) & daysAll,
        enabled: j['enabled'] as bool? ?? true,
        snooze: j['snooze'] as bool? ?? true,
        label: j['label'] as String? ?? '',
      );

  /// Minutes after local midnight.
  final int minutes;
  final int days;
  final bool enabled;
  final bool snooze;
  final String label;

  Alarm copyWith({int? minutes, int? days, bool? enabled, bool? snooze}) => Alarm(
        minutes: minutes ?? this.minutes,
        days: days ?? this.days,
        enabled: enabled ?? this.enabled,
        snooze: snooze ?? this.snooze,
        label: label,
      );

  bool sameTime(Alarm o) => o.minutes == minutes && o.days == days;

  Map<String, dynamic> toJson() =>
      {'minutes': minutes, 'days': days, 'enabled': enabled, 'snooze': snooze, if (label.isNotEmpty) 'label': label};
}

class ClockBook {
  ClockBook({
    List<Alarm>? alarms,
    List<String>? world,
    this.timerEnd,
    this.timerSeconds = 0,
    this.snoozeUntil,
    this.snoozeAlarm,
    this.checked,
  })  : alarms = alarms ?? [],
        world = world ?? [];

  factory ClockBook.fromJson(Map<String, dynamic> j) => ClockBook(
        alarms: [for (final a in (j['alarms'] as List? ?? const [])) Alarm.fromJson(a as Map<String, dynamic>)],
        world: [for (final z in (j['world'] as List? ?? const [])) '$z'],
        timerEnd: (j['timer_end'] as num?)?.toInt(),
        timerSeconds: (j['timer_seconds'] as num?)?.toInt() ?? 0,
        snoozeUntil: (j['snooze_until'] as num?)?.toInt(),
        snoozeAlarm: (j['snooze_alarm'] as num?)?.toInt(),
        checked: (j['checked'] as num?)?.toInt(),
      );

  final List<Alarm> alarms;

  /// IANA zone names.
  final List<String> world;

  /// A running timer's end (UTC seconds) and its length.
  int? timerEnd;
  int timerSeconds;

  /// A snoozed alarm rings again at [snoozeUntil] (UTC seconds).
  int? snoozeUntil;
  int? snoozeAlarm;

  /// The last instant the schedule was checked (UTC seconds).
  int? checked;

  Map<String, dynamic> toJson() => {
        'alarms': [for (final a in alarms) a.toJson()],
        'world': world,
        if (timerEnd != null) 'timer_end': timerEnd,
        'timer_seconds': timerSeconds,
        if (snoozeUntil != null) 'snooze_until': snoozeUntil,
        if (snoozeAlarm != null) 'snooze_alarm': snoozeAlarm,
        if (checked != null) 'checked': checked,
      };

  /// Read the book; an empty one if there is none yet or it is unreadable.
  static Future<ClockBook> load(String path) async {
    try {
      return ClockBook.fromJson(jsonDecode(await File(path).readAsString()) as Map<String, dynamic>);
    } on Object {
      return ClockBook();
    }
  }

  /// Write the book whole (the kit's atomic write), so a power cut
  /// leaves one book or the other, never half of one.
  Future<void> save(String path) => VrxFile.writeAtomic(path, jsonEncode(toJson()));
}

/// What is due: an alarm (its index) or the timer.
enum FireKind { alarm, timer }

class Due {
  const Due(this.kind, [this.index = 0]);

  final FireKind kind;
  final int index;
}

/// The next instant [alarm] rings after [after] (UTC seconds), in [zone].
int nextRing(Alarm alarm, int after, Zone zone) {
  final today = zone.local(after);
  for (var d = 0; d <= 7; d++) {
    final date = DateTime.utc(today.year, today.month, today.day + d);
    if (alarm.days != 0 && alarm.days & (1 << (date.weekday % 7)) == 0) continue;
    final at = zone.utcOf(date.add(Duration(minutes: alarm.minutes)));
    if (at > after) return at;
  }
  return after + 8 * 86400; // unreachable: some day in eight matches
}

/// Everything that came due in (book.checked, now], and the book
/// updated for it: a one-off alarm switches off, the timer and the
/// snooze clear, and the check moves to [now].
List<Due> takeDue(ClockBook book, int now, Zone zone) {
  final since = book.checked ?? now;
  final due = <Due>[];
  for (var i = 0; i < book.alarms.length; i++) {
    final a = book.alarms[i];
    if (!a.enabled) continue;
    final at = nextRing(a, since, zone);
    if (at > now) continue;
    if (now - at <= lateSeconds) due.add(Due(FireKind.alarm, i));
    if (a.days == 0) book.alarms[i] = a.copyWith(enabled: false);
  }
  final snooze = book.snoozeUntil;
  if (snooze != null && snooze <= now) {
    final i = book.snoozeAlarm ?? -1;
    if (i >= 0 && i < book.alarms.length) due.add(Due(FireKind.alarm, i));
    book
      ..snoozeUntil = null
      ..snoozeAlarm = null;
  }
  final end = book.timerEnd;
  if (end != null && end <= now) {
    due.add(const Due(FireKind.timer));
    book.timerEnd = null;
  }
  book.checked = now;
  return due;
}

/// The next instant anything in [book] comes due after [now], or null.
int? nextDue(ClockBook book, int now, Zone zone) {
  int? best;
  void take(int? t) {
    if (t != null && (best == null || t < best!)) best = t;
  }

  for (final a in book.alarms) {
    if (a.enabled) take(nextRing(a, now, zone));
  }
  take(book.snoozeUntil);
  take(book.timerEnd);
  return best;
}

/// "Weekdays", "Every day", "Once", or "Mon Wed Fri".
String describeDays(int mask) {
  const short = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
  return switch (mask) {
    0 => 'Once',
    daysAll => 'Every day',
    daysWeek => 'Weekdays',
    daysWeekend => 'Weekends',
    _ => [for (var i = 0; i < 7; i++) if (mask & (1 << i) != 0) short[i]].join(' '),
  };
}

/// "07:45" from minutes after midnight; "7:45 AM" in 12-hour form (the
/// kit's one formatter, VrxTimeFormat.hm).
String hm(int minutes, {bool h12 = false}) => VrxTimeFormat.hm(minutes, h24: !h12);
