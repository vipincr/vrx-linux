import 'package:vrx_kit/vrx_kit.dart';

import 'book.dart';
import 'tz.dart';

/// The clock's events. The model's methods make the changes (each a
/// rule ported from evrx-rt's clock model); an event says the view is
/// due again.
enum ClockAction { init, changed, tick }

/// Screens over the tabs. The tabs are one screen: a tab change is
/// state, not a push, so Back leaves the applet from any tab.
enum ClockScreen { tabs, zones, editor, editTime }

enum ClockTab { face, world, alarms, timer }

enum TimerMode { pomodoro, precise }

/// The pomodoro dial's five stops, clockwise from the top; it opens on
/// 20 minutes.
const dialMinutes = [1, 5, 20, 45, 60];
const dialDefault = 2;
const preciseMax = 60;

/// The progress ring redraws this many times over a whole run, whatever
/// its length (evrx-rt: twelve repaints, not one a second).
const ringSteps = 12;

class Ring {
  const Ring(this.kind, this.index, this.started);

  final FireKind kind;
  final int index;
  final int started;
}

class ClockView {
  const ClockView({
    required this.screen,
    required this.tab,
    required this.valid,
    required this.time,
    required this.date,
    required this.zone,
    required this.next,
    required this.cities,
    required this.canAddCity,
    required this.alarms,
    required this.canAddAlarm,
    required this.mode,
    required this.dial,
    required this.precise,
    required this.running,
    required this.centre,
    required this.ringValue,
    required this.pickHome,
    required this.zones,
    required this.draft,
    required this.canDelete,
    required this.notice,
    required this.ring,
    required this.ringNote,
    required this.ringIsTimer,
    required this.canSnooze,
    required this.h12,
  });

  final ClockScreen screen;
  final ClockTab tab;

  /// The clock has been set (synced, or a plausible year).
  final bool valid;
  final String time;
  final String date;
  final String zone;
  final String next;

  /// (city, "07:45 +1", the zone)
  final List<(String, String, String)> cities;
  final bool canAddCity;

  /// (time, days, on)
  final List<(String, String, bool)> alarms;
  final bool canAddAlarm;

  final TimerMode mode;
  final int dial;
  final int precise;
  final bool running;

  /// The dial's centre: minutes set, or minutes left (rounded up).
  final String centre;

  /// Steps of [ringSteps] left; [ringSteps] when nothing runs.
  final int ringValue;

  /// The zone picker chooses the home zone (else a world city).
  final bool pickHome;
  final List<String> zones;

  final Alarm draft;
  final bool canDelete;
  final String notice;

  /// Ringing: covers whatever screen is up.
  final bool ring;
  final String ringNote;
  final bool ringIsTimer;
  final bool canSnooze;

  /// Times in 12-hour form (the clock_format setting).
  final bool h12;
}

class ClockModel extends StoreModel<ClockState, ClockAction, ClockView> {
  ClockModel({ClockBook? book, int Function()? now})
      : book = book ?? ClockBook(),
        _now = now ?? _wallClock;

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  final int Function() _now;
  ClockBook book;
  Zone home = Zone.fixed('UTC', 0);
  final world = <String, Zone>{};
  bool synced = false;
  List<String> zones = const [];

  ClockTab tab = ClockTab.face;
  final _stack = <ClockScreen>[ClockScreen.tabs];
  bool pickHome = false;

  int editing = -1;
  Alarm draft = const Alarm(minutes: 420);
  String notice = '';

  TimerMode mode = TimerMode.pomodoro;
  int dial = dialDefault;
  int precise = 20;

  Ring? ring;

  /// The declared clock_format setting (plan 0008 D5) is 12h.
  bool h12 = false;

  int get now => _now();
  ClockScreen get screen => _stack.last;

  /// Back within the applet; false when Back should leave it.
  bool back() {
    if (ring != null || _stack.length == 1) return false;
    _stack.removeLast();
    notice = '';
    return true;
  }

  void _push(ClockScreen s) => _stack.add(s);
  void _toTabs() => _stack
    ..clear()
    ..add(ClockScreen.tabs);

  void openTab(ClockTab t) {
    if (ring == null && screen == ClockScreen.tabs) tab = t;
  }

  // ── zones ──────────────────────────────────────────────────────────

  /// The face's zone row: choose the home zone (the system's).
  void pickHomeZone() {
    if (ring != null || screen != ClockScreen.tabs) return;
    pickHome = true;
    _push(ClockScreen.zones);
  }

  void addCity() {
    if (ring != null || screen != ClockScreen.tabs || book.world.length >= worldMax) return;
    pickHome = false;
    _push(ClockScreen.zones);
  }

  /// A zone was picked: a world city joins the list; the home zone the
  /// caller sets through timedated. Back to the tabs either way.
  void pickZone(String zone) {
    if (screen != ClockScreen.zones) return;
    if (!pickHome && !book.world.contains(zone) && book.world.length < worldMax) book.world.add(zone);
    _toTabs();
  }

  void removeCity(int i) {
    if (i >= 0 && i < book.world.length) book.world.removeAt(i);
  }

  // ── alarms ─────────────────────────────────────────────────────────

  void newAlarm() {
    if (ring != null || screen != ClockScreen.tabs || book.alarms.length >= alarmsMax) return;
    draft = const Alarm(minutes: 7 * 60); // the alarm most people set
    editing = -1;
    notice = '';
    _push(ClockScreen.editor);
  }

  void editAlarm(int i) {
    if (ring != null || screen != ClockScreen.tabs || i < 0 || i >= book.alarms.length) return;
    editing = i;
    draft = book.alarms[i]; // a copy: the book may change under an edit
    notice = '';
    _push(ClockScreen.editor);
  }

  void toggleAlarm(int i) {
    if (i < 0 || i >= book.alarms.length) return;
    book.alarms[i] = book.alarms[i].copyWith(enabled: !book.alarms[i].enabled);
    // a re-enabled one-off rings at its next time, not at a missed one
    book.checked = now;
  }

  void removeAlarm(int i) {
    if (i < 0 || i >= book.alarms.length) return;
    book.alarms.removeAt(i);
    final s = book.snoozeAlarm;
    if (s == i) {
      book
        ..snoozeAlarm = null
        ..snoozeUntil = null;
    } else if (s != null && s > i) {
      book.snoozeAlarm = s - 1;
    }
  }

  void editTime() {
    if (screen == ClockScreen.editor) _push(ClockScreen.editTime);
  }

  void setDraftTime(int minutes) {
    if (screen != ClockScreen.editTime) return;
    draft = draft.copyWith(minutes: minutes.clamp(0, 1439));
    _stack.removeLast();
  }

  /// Four presets rather than seven checkboxes: these cover what people
  /// set, and seven toggles is seven taps to say "weekdays".
  void cycleDays() {
    if (screen != ClockScreen.editor) return;
    draft = draft.copyWith(
        days: switch (draft.days) { 0 => daysAll, daysAll => daysWeek, daysWeek => daysWeekend, _ => 0 });
  }

  void toggleSnooze() {
    if (screen == ClockScreen.editor) draft = draft.copyWith(snooze: !draft.snooze);
  }

  /// Save the draft; stays on the editor and says why when it cannot.
  bool saveDraft() {
    if (screen != ClockScreen.editor) return false;
    final others = [for (var i = 0; i < book.alarms.length; i++) if (i != editing) book.alarms[i]];
    if (others.any(draft.sameTime)) {
      notice = 'That alarm is already set.';
      return false;
    }
    if (editing < 0 && book.alarms.length >= alarmsMax) {
      notice = 'There is no room for another alarm.';
      return false;
    }
    final saved = draft.copyWith(enabled: true);
    if (editing < 0) {
      book.alarms.add(saved);
    } else {
      book.alarms[editing] = saved;
    }
    book.checked = now;
    notice = '';
    _stack.removeLast();
    return true;
  }

  void deleteDraft() {
    if (screen != ClockScreen.editor || editing < 0) return;
    removeAlarm(editing);
    editing = -1;
    _stack.removeLast();
  }

  // ── the timer ──────────────────────────────────────────────────────

  bool get _onTimer => ring == null && screen == ClockScreen.tabs && tab == ClockTab.timer;
  bool get running => (book.timerEnd ?? 0) > now;

  void setMode(TimerMode m) {
    if (_onTimer) mode = m;
  }

  void pickDial(int i) {
    if (_onTimer && mode == TimerMode.pomodoro && !running && i >= 0 && i < dialMinutes.length) dial = i;
  }

  void setPrecise(int minutes) {
    if (_onTimer && mode == TimerMode.precise && !running) precise = minutes.clamp(1, preciseMax);
  }

  /// The dial's centre: start what is set, or stop what runs.
  void pressDial() {
    if (!_onTimer) return;
    if (running) {
      book.timerEnd = null;
      return;
    }
    final seconds = (mode == TimerMode.precise ? precise : dialMinutes[dial]) * 60;
    book
      ..timerSeconds = seconds
      ..timerEnd = now + seconds;
  }

  /// A hold: stop, and put the ring back to full.
  void resetTimer() {
    if (_onTimer) book.timerEnd = null;
  }

  // ── the ring ───────────────────────────────────────────────────────

  /// Check the schedule; the first thing due rings (one at a time).
  /// True when the book changed and wants saving.
  bool check() {
    final before = book.toJson().toString();
    final due = takeDue(book, now, home);
    if (due.isNotEmpty && ring == null) {
      final d = due.first;
      ring = Ring(d.kind, d.index, now);
      // the ring ends on a tab, so the stack goes back to the tabs now
      _toTabs();
    }
    return book.toJson().toString() != before;
  }

  bool get canSnooze {
    final r = ring;
    return r != null && r.kind == FireKind.alarm && r.index < book.alarms.length && book.alarms[r.index].snooze;
  }

  /// Stop the ring. A finished timer returns to the timer; an alarm to
  /// the face (it happened; it is not a tool being used).
  void stopRing() {
    final r = ring;
    if (r == null) return;
    ring = null;
    tab = r.kind == FireKind.timer ? ClockTab.timer : ClockTab.face;
  }

  /// Snooze; on an alarm without snooze, or a timer, it stops: a button
  /// that does nothing reads as broken.
  void snoozeRing() {
    final r = ring;
    if (r == null) return;
    if (canSnooze) {
      book
        ..snoozeUntil = now + snoozeMinutes * 60
        ..snoozeAlarm = r.index;
    }
    stopRing();
  }

  /// An alarm nobody is there for gives up.
  bool get ringExpired => ring != null && now - ring!.started >= ringSeconds;

  // ── the view ───────────────────────────────────────────────────────

  @override
  ClockState get initial => const ClockState();

  @override
  ClockAction get bootAction => ClockAction.init;

  @override
  ClockState get snapshot => const ClockState();

  @override
  ClockView reduce(ClockState state, ClockAction action) {
    final t = now;
    final wall = home.local(t);
    final valid = synced || wall.year >= 2025;
    const days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June', //
      'July', 'August', 'September', 'October', 'November', 'December',
    ];
    var next = '';
    final snooze = book.snoozeUntil;
    final due = nextDue(book, t, home);
    if (due != null) {
      final s = home.local(due);
      next = snooze == due
          ? 'Snoozed until ${hm(s.hour * 60 + s.minute, h12: h12)}.'
          : 'Next ${due == book.timerEnd ? 'timer' : 'alarm'} at ${hm(s.hour * 60 + s.minute, h12: h12)}.';
    }
    final homeDay = DateTime.utc(wall.year, wall.month, wall.day);
    final cities = <(String, String, String)>[];
    for (final z in book.world) {
      final w = (world[z] ?? Zone.fixed(z, 0)).local(t);
      final shift = DateTime.utc(w.year, w.month, w.day).difference(homeDay).inDays;
      final mark = shift == 0 ? '' : (shift > 0 ? ' +$shift' : ' −${-shift}');
      cities.add((vrxCityOf(z), '${hm(w.hour * 60 + w.minute, h12: h12)}$mark', z));
    }
    final left = (book.timerEnd ?? 0) - t;
    final run = left > 0;
    final setMinutes = mode == TimerMode.precise ? precise : dialMinutes[dial];
    final total = book.timerSeconds;
    final r = ring;
    var ringNote = '';
    if (r != null) {
      ringNote = r.kind == FireKind.timer
          ? 'The timer has finished.'
          : (r.index < book.alarms.length && book.alarms[r.index].label.isNotEmpty
              ? book.alarms[r.index].label
              : 'Alarm.');
    }
    return ClockView(
      screen: screen,
      tab: tab,
      valid: valid,
      time: valid ? hm(wall.hour * 60 + wall.minute, h12: h12) : '--:--',
      date: valid ? '${days[wall.weekday - 1]} ${wall.day} ${months[wall.month - 1]}' : '',
      zone: home.name,
      next: next,
      cities: cities,
      canAddCity: book.world.length < worldMax,
      alarms: [for (final a in book.alarms) (hm(a.minutes, h12: h12), describeDays(a.days), a.enabled)],
      canAddAlarm: book.alarms.length < alarmsMax,
      mode: mode,
      dial: dial,
      precise: precise,
      running: run,
      centre: '${run ? ((left + 59) ~/ 60).clamp(0, 999) : setMinutes}',
      ringValue: !run ? ringSteps : (total <= 0 ? 0 : (ringSteps * left.clamp(0, total) + total - 1) ~/ total),
      pickHome: pickHome,
      zones: zones,
      draft: draft,
      canDelete: editing >= 0,
      notice: notice,
      ring: r != null,
      ringNote: ringNote,
      ringIsTimer: r?.kind == FireKind.timer,
      canSnooze: canSnooze,
      h12: h12,
    );
  }
}

class ClockState {
  const ClockState();
}
