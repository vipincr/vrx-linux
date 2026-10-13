import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

import 'package:clock_applet/book.dart';
import 'package:clock_applet/state.dart';
import 'package:clock_applet/tz.dart';

void main() {
  // 2026-10-15 01:30 UTC, 07:00 in Kolkata, a Thursday
  final start = DateTime.utc(2026, 10, 15, 1, 30).millisecondsSinceEpoch ~/ 1000;
  var clock = start;
  setUp(() => clock = start);
  ClockModel model() => ClockModel(now: () => clock)..home = Zone.fixed('Asia/Kolkata', 19800);

  test('the face reads the home zone and names the next alarm', () {
    final m = model()..book.alarms.add(const Alarm(minutes: 7 * 60 + 30, days: daysAll));
    final h = StoreHarness(m);
    h.assertView((v) => v.time == '07:00' && v.date == 'Thursday 15 October' && v.next == 'Next alarm at 07:30.');
  });

  test('an alarm is made in the editor; a duplicate stays and says why', () {
    final m = model();
    final h = StoreHarness(m);
    m
      ..openTab(ClockTab.alarms)
      ..newAlarm()
      ..cycleDays(); // Every day
    h.dispatch(ClockAction.changed);
    h.assertView((v) => v.screen == ClockScreen.editor && v.draft.days == daysAll);
    expect(m.saveDraft(), isTrue);
    h.dispatch(ClockAction.changed);
    h.assertView((v) => v.screen == ClockScreen.tabs && v.alarms.single == ('07:00', 'Every day', true));
    m
      ..newAlarm()
      ..cycleDays();
    expect(m.saveDraft(), isFalse);
    h.dispatch(ClockAction.changed);
    h.assertView((v) => v.notice == 'That alarm is already set.');
  });

  test('the timer runs down in minutes and twelve ring steps', () {
    final m = model()..openTab(ClockTab.timer);
    final h = StoreHarness(m);
    m.pressDial(); // 20 minutes
    h.dispatch(ClockAction.changed);
    h.assertView((v) => v.running && v.centre == '20' && v.ringValue == ringSteps);
    clock += 10 * 60 + 1;
    h.dispatch(ClockAction.tick);
    h.assertView((v) => v.centre == '10' && v.ringValue == 6);
    m.pressDial(); // stops it
    h.dispatch(ClockAction.changed);
    h.assertView((v) => !v.running && v.centre == '20');
  });

  test('a due alarm rings over any screen; snooze rings again in nine minutes', () {
    final m = model()
      ..book.alarms.add(const Alarm(minutes: 7 * 60 + 1, days: daysAll))
      ..book.checked = clock
      ..openTab(ClockTab.alarms)
      ..editAlarm(0);
    clock += 60;
    expect(m.check(), isTrue);
    final h = StoreHarness(m);
    h.assertView((v) => v.ring && v.canSnooze && v.ringNote == 'Alarm.');
    m.snoozeRing();
    h.dispatch(ClockAction.changed);
    h.assertView((v) => !v.ring && v.tab == ClockTab.face && v.next == 'Snoozed until 07:10.');
    clock += snoozeMinutes * 60;
    m.check();
    expect(m.ring?.index, 0);
    clock += ringSeconds;
    expect(m.ringExpired, isTrue);
  });

  test('a city is chosen by region, and the world clock marks the next day', () {
    final m = model()
      ..zones = ['Asia/Kolkata', 'Pacific/Auckland', 'Europe/London']
      ..world['Pacific/Auckland'] = Zone.fixed('Pacific/Auckland', 46800)
      ..openTab(ClockTab.world)
      ..addCity();
    final h = StoreHarness(m);
    h.assertView((v) => v.screen == ClockScreen.regions && v.list.join(',') == 'Asia,Europe,Pacific Ocean');
    m.pickRegion(2);
    h.dispatch(ClockAction.changed);
    h.assertView((v) => v.screen == ClockScreen.cities && v.list.single == 'Auckland');
    expect(m.pickCity(0), 'Pacific/Auckland');
    h.dispatch(ClockAction.changed);
    // 01:30 UTC is 14:30 in Auckland, the same Thursday
    h.assertView((v) => v.cities.single == ('Auckland', '14:30', 'Pacific/Auckland'));
    clock += 10 * 3600; // 11:30 UTC: 00:30 Friday in Auckland
    h.dispatch(ClockAction.tick);
    h.assertView((v) => v.cities.single.$2 == '00:30 +1');
  });
}
