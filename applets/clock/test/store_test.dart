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

  test('a city joins the world clock, and the world clock marks the next day', () {
    final m = model()
      ..zones = ['Asia/Kolkata', 'Pacific/Auckland', 'Europe/London']
      ..world['Pacific/Auckland'] = Zone.fixed('Pacific/Auckland', 46800)
      ..openTab(ClockTab.world)
      ..addCity();
    final h = StoreHarness(m);
    h.assertView((v) => v.screen == ClockScreen.zones && !v.pickHome && v.zones.length == 3);
    m.pickZone('Pacific/Auckland');
    h.dispatch(ClockAction.changed);
    // 01:30 UTC is 14:30 in Auckland, the same Thursday
    h.assertView((v) => v.screen == ClockScreen.tabs && v.cities.single == ('Auckland', '14:30', 'Pacific/Auckland'));
    clock += 10 * 3600; // 11:30 UTC: 00:30 Friday in Auckland
    h.dispatch(ClockAction.tick);
    h.assertView((v) => v.cities.single.$2 == '00:30 +1');
  });

  test('the 12-hour setting changes every time the clock shows', () {
    final m = model()..book.alarms.add(const Alarm(minutes: 13 * 60 + 5, days: daysAll));
    final h = StoreHarness(m);
    h.assertView((v) => v.time == '07:00' && v.next == 'Next alarm at 13:05.');
    m.h12 = true;
    h.dispatch(ClockAction.changed);
    h.assertView((v) => v.time == '7:00 AM' && v.next == 'Next alarm at 1:05 PM.' && v.h12);
  });

  // plan 0010 D3 after the bench (2026-10-14): the ring holds the screen
  // through the model, read by the store after a reduce. No widget is
  // built here (a plain test, no binding), as none is while the screen
  // is off and Clock is hidden.
  test('a ring holds the screen from the store, with no build; it lets go when it ends', () {
    final keeper = _Keeper();
    Store.keeper = keeper;
    addTearDown(() => Store.keeper = null);
    final m = model()
      ..book.alarms.add(const Alarm(minutes: 7 * 60 + 1, days: daysAll))
      ..book.checked = clock;
    final h = StoreHarness(m);
    expect(keeper.events, isEmpty);
    clock += 60;
    expect(m.check(), isTrue); // what the scheduler's Timer does
    h.dispatch(ClockAction.tick);
    expect(keeper.events, ['hold an alarm or timer is ringing']);
    h.dispatch(ClockAction.tick);
    expect(keeper.events, hasLength(1), reason: 'one hold while it rings');
    m.stopRing();
    h.dispatch(ClockAction.changed);
    expect(keeper.events, ['hold an alarm or timer is ringing', 'release']);
    // snooze ends a ring too
    clock += 24 * 3600;
    m.check();
    h.dispatch(ClockAction.tick);
    m.snoozeRing();
    h.dispatch(ClockAction.changed);
    expect(keeper.events.last, 'release');
  });
  test("the store's promises hold over the world's facts and Back (plan 0013 D2)", () {
    final h = StoreHarness(model());
    h.dispatch(ClockFacts(home: Zone.fixed('Europe/London', 3600), synced: true));
    h.dispatch(const ClockFacts(h12: true, zones: ['Asia/Kolkata', 'Europe/London']));
    h.dispatch(ClockFacts(book: ClockBook(alarms: [const Alarm(minutes: 8 * 60, days: daysAll)])));
    h.dispatch(ClockAction.tick);
    h.dispatch(ClockAction.back);
    h.assertView((v) => v.h12 && v.time.endsWith('AM') && v.next == 'Next alarm at 8:00 AM.');
    h.verify(fresh: model, probes: const [ClockAction.changed, ClockAction.tick, ClockAction.back]);
  });
}

class _Keeper implements ScreenKeeper {
  final events = <String>[];

  @override
  void hold(String why) => events.add('hold $why');

  @override
  void release() => events.add('release');

}
