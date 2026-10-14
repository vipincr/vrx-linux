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

  // the reduce budget measures the reducer, not the JIT: dispatch each
  // kind once, untimed, before the timed tests (the shell and Settings do
  // the same). The gate runs test files side by side, and a first dispatch
  // compiled there overran 2 ms; the shipped applet is AOT-compiled.
  setUpAll(() {
    final m = model()..book.alarms.add(const Alarm(minutes: 7 * 60 + 1, days: daysAll));
    final h = StoreHarness(m, reduceBudget: const Duration(days: 1));
    for (final a in <ClockAction>[
      const ClockOpenTab(ClockTab.alarms),
      const ClockEditAlarm(0),
      ClockDo.check,
      ClockDo.newAlarm,
      ClockDo.cycleDays,
      ClockDo.saveDraft,
      ClockAction.tick,
      const ClockFacts(h12: true),
    ]) {
      h.dispatch(a);
    }
  });

  test('the face reads the home zone and names the next alarm', () {
    final m = model()..book.alarms.add(const Alarm(minutes: 7 * 60 + 30, days: daysAll));
    final h = StoreHarness(m);
    h.assertView((v) => v.time == '07:00' && v.date == 'Thursday 15 October' && v.next == 'Next alarm at 07:30.');
  });

  test('an alarm is made in the editor; a duplicate stays and says why', () {
    final m = model();
    final h = StoreHarness(m);
    h
      ..dispatch(const ClockOpenTab(ClockTab.alarms))
      ..dispatch(ClockDo.newAlarm)
      ..dispatch(ClockDo.cycleDays); // Every day
    h.assertView((v) => v.screen == ClockScreen.editor && v.draft.days == daysAll);
    h.dispatch(ClockDo.saveDraft);
    expect(m.takeSave(), isTrue, reason: 'a saved alarm is written to the book');
    h.assertView((v) => v.screen == ClockScreen.tabs && v.alarms.single == ('07:00', 'Every day', true));
    h
      ..dispatch(ClockDo.newAlarm)
      ..dispatch(ClockDo.cycleDays)
      ..dispatch(ClockDo.saveDraft);
    h.assertView((v) => v.screen == ClockScreen.editor && v.notice == 'That alarm is already set.');
  });

  test('the timer runs down in minutes and twelve ring steps', () {
    final h = StoreHarness(model())
      ..dispatch(const ClockOpenTab(ClockTab.timer))
      ..dispatch(ClockDo.pressDial); // 20 minutes
    h.assertView((v) => v.running && v.centre == '20' && v.ringValue == ringSteps);
    clock += 10 * 60 + 1;
    h.dispatch(ClockAction.tick);
    h.assertView((v) => v.centre == '10' && v.ringValue == 6);
    h.dispatch(ClockDo.pressDial); // stops it
    h.assertView((v) => !v.running && v.centre == '20');
  });

  test('a due alarm rings over any screen; snooze rings again in nine minutes', () {
    final m = model()
      ..book.alarms.add(const Alarm(minutes: 7 * 60 + 1, days: daysAll))
      ..book.checked = clock;
    final h = StoreHarness(m)
      ..dispatch(const ClockOpenTab(ClockTab.alarms))
      ..dispatch(const ClockEditAlarm(0));
    clock += 60;
    h.dispatch(ClockDo.check); // what the scheduler's Timer sends
    expect(m.takeSave(), isTrue);
    h.assertView((v) => v.ring && v.canSnooze && v.ringNote == 'Alarm.');
    h.dispatch(ClockDo.snoozeRing);
    h.assertView((v) => !v.ring && v.tab == ClockTab.face && v.next == 'Snoozed until 07:10.');
    clock += snoozeMinutes * 60;
    h.dispatch(ClockDo.check);
    expect(m.ring?.index, 0);
    clock += ringSeconds;
    expect(m.ringExpired, isTrue);
  });

  test('a city joins the world clock, and the world clock marks the next day', () {
    final m = model()
      ..zones = ['Asia/Kolkata', 'Pacific/Auckland', 'Europe/London']
      ..world['Pacific/Auckland'] = Zone.fixed('Pacific/Auckland', 46800);
    final h = StoreHarness(m)
      ..dispatch(const ClockOpenTab(ClockTab.world))
      ..dispatch(ClockDo.addCity);
    h.assertView((v) => v.screen == ClockScreen.zones && !v.pickHome && v.zones.length == 3);
    h.dispatch(const ClockPickZone('Pacific/Auckland'));
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
    h.dispatch(const ClockFacts(h12: true));
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
    h.dispatch(ClockDo.check); // what the scheduler's Timer sends
    expect(keeper.events, ['hold an alarm or timer is ringing']);
    h.dispatch(ClockAction.tick);
    expect(keeper.events, hasLength(1), reason: 'one hold while it rings');
    h.dispatch(ClockDo.stopRing);
    expect(keeper.events, ['hold an alarm or timer is ringing', 'release']);
    // snooze ends a ring too
    clock += 24 * 3600;
    h
      ..dispatch(ClockDo.check)
      ..dispatch(ClockDo.snoozeRing);
    expect(keeper.events.last, 'release');
  });
  test('a home app arms and disarms every alarm (plan 0015 D7)', () {
    final m = model();
    StoreHarness(m)
      ..dispatch(ClockFacts(
          book: ClockBook(alarms: [const Alarm(minutes: 7 * 60), const Alarm(minutes: 8 * 60, enabled: false)])))
      ..dispatch(const ClockArmAlarms(true));
    expect(m.book.alarms.every((a) => a.enabled), isTrue);
    expect(m.takeSave(), isTrue, reason: 'the book is written');
    StoreHarness(m).dispatch(const ClockArmAlarms(false));
    expect(m.book.alarms.any((a) => a.enabled), isFalse);
  });
  test("the store's promises hold over the world's facts and Back (plan 0013 D2)", () {
    final h = StoreHarness(model());
    h.dispatch(ClockFacts(home: Zone.fixed('Europe/London', 3600), synced: true));
    h.dispatch(const ClockFacts(h12: true, zones: ['Asia/Kolkata', 'Europe/London']));
    h.dispatch(ClockFacts(book: ClockBook(alarms: [const Alarm(minutes: 8 * 60, days: daysAll)])));
    h.dispatch(ClockAction.tick);
    h.dispatch(ClockAction.back);
    h.assertView((v) => v.h12 && v.time.endsWith('AM') && v.next == 'Next alarm at 8:00 AM.');
    // every edit a person can make is in the probes, so replay and
    // totality cover the paths the view drives (plan 0013 D2)
    h.verify(fresh: model, probes: const [
      ClockAction.tick,
      ClockAction.back,
      ClockOpenTab(ClockTab.alarms),
      ClockDo.newAlarm,
      ClockDo.cycleDays,
      ClockDo.toggleSnooze,
      ClockDo.editTime,
      ClockDraftTime(8 * 60 + 15),
      ClockDo.saveDraft,
      ClockToggleAlarm(0),
      ClockArmAlarms(false),
      ClockArmAlarms(true),
      ClockEditAlarm(0),
      ClockDo.deleteDraft,
      ClockRemoveAlarm(0),
      ClockOpenTab(ClockTab.world),
      ClockDo.addCity,
      ClockPickZone('Europe/London'),
      ClockRemoveCity(0),
      ClockDo.pickHomeZone,
      ClockOpenTab(ClockTab.timer),
      ClockTimerMode(TimerMode.precise),
      ClockPrecise(25),
      ClockTimerMode(TimerMode.pomodoro),
      ClockPickDial(1),
      ClockDo.pressDial,
      ClockDo.resetTimer,
      ClockDo.check,
      ClockDo.stopRing,
      ClockDo.snoozeRing,
    ]);
  });
}

class _Keeper implements ScreenKeeper {
  final events = <String>[];

  @override
  void hold(String why) => events.add('hold $why');

  @override
  void release() => events.add('release');

}
