import 'package:flutter_test/flutter_test.dart';

import 'package:clock_applet/book.dart';
import 'package:clock_applet/tz.dart';

int utc(int y, int mo, int d, [int h = 0, int mi = 0]) => DateTime.utc(y, mo, d, h, mi).millisecondsSinceEpoch ~/ 1000;

void main() {
  final ist = Zone.fixed('Asia/Kolkata', 19800);

  test('a weekday alarm skips the weekend, in the home zone', () {
    // Friday 2026-10-16 08:00 IST is 02:30 UTC; next is Monday 07:00 IST
    const a = Alarm(minutes: 7 * 60, days: daysWeek);
    expect(nextRing(a, utc(2026, 10, 16, 2, 30), ist), utc(2026, 10, 19, 1, 30));
    // Thursday 06:00 IST: the same day
    expect(nextRing(a, utc(2026, 10, 15, 0, 30), ist), utc(2026, 10, 15, 1, 30));
  });

  test('due: a one-off rings once and switches off; a long-missed one does not ring', () {
    final book = ClockBook(alarms: [const Alarm(minutes: 7 * 60), const Alarm(minutes: 6 * 60, days: daysAll)]);
    book.checked = utc(2026, 10, 15, 1, 29);
    final due = takeDue(book, utc(2026, 10, 15, 1, 30), ist);
    expect(due.map((d) => d.index), [0]);
    expect(book.alarms[0].enabled, isFalse);
    // the device was off from 05:00 to 07:30 IST: the 06:00 alarm is
    // more than ten minutes late and stays quiet
    book.checked = utc(2026, 10, 15, 23, 30);
    expect(takeDue(book, utc(2026, 10, 16, 2), ist), isEmpty);
    expect(book.alarms[1].enabled, isTrue, reason: 'a repeating alarm stays on');
  });

  test('due: the timer and a snooze', () {
    final book = ClockBook(alarms: [const Alarm(minutes: 0, days: daysAll)])
      ..checked = 100
      ..timerEnd = 150
      ..snoozeUntil = 160
      ..snoozeAlarm = 0;
    final due = takeDue(book, 200, ist);
    expect(due.map((d) => d.kind), [FireKind.alarm, FireKind.timer]);
    expect(book.timerEnd, isNull);
    expect(book.snoozeUntil, isNull);
    expect(nextDue(book, 200, ist), nextRing(book.alarms[0], 200, ist));
  });

  test('days read as people say them; the book round-trips', () {
    expect(describeDays(0), 'Once');
    expect(describeDays(daysAll), 'Every day');
    expect(describeDays(daysWeek), 'Weekdays');
    expect(describeDays(daysWeekend), 'Weekends');
    expect(describeDays(0x2a), 'Mon Wed Fri');
    final book = ClockBook(alarms: [const Alarm(minutes: 90, days: 3, snooze: false)], world: ['Europe/London'])
      ..timerEnd = 5
      ..timerSeconds = 60;
    final back = ClockBook.fromJson(book.toJson());
    expect(back.toJson(), book.toJson());
    expect(cityOf('America/Argentina/Buenos_Aires'), 'Buenos Aires');
    expect(hm(7 * 60 + 5), '07:05');
  });
}
