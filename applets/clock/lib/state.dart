import 'package:vrx_kit/vrx_kit.dart';

import 'book.dart';
import 'tz.dart';

/// Everything the applet reacts to: a signal, or facts from the world
/// carried as data (plan 0013 D1: the reducer is the only writer).
sealed class ClockAction {
  const ClockAction();

  static const init = ClockSignal.init;
  static const tick = ClockSignal.tick;
  static const back = ClockSignal.back;
}

enum ClockSignal implements ClockAction { init, tick, back }

/// The world's facts (null fields: unchanged): the book read from its
/// file, the home zone's rules, network time, the locale's 12 or 24
/// hours, the zone list, and world cities' rules as they load.
final class ClockFacts implements ClockAction {
  const ClockFacts({this.book, this.home, this.synced, this.h12, this.zones, this.world});

  final ClockBook? book;
  final Zone? home;
  final bool? synced;
  final bool? h12;
  final List<String>? zones;
  final Map<String, Zone>? world;

  @override
  String toString() => 'ClockFacts(book: ${book != null}, home: ${home?.name}, synced: $synced, h12: $h12, '
      'zones: ${zones?.length}, world: ${world?.keys.toList()})';
}

/// What a person did, or the schedule's turn, with nothing to carry
/// (plan 0013 D1): the reducer applies each; nothing else edits the model.
enum ClockDo implements ClockAction {
  pickHomeZone,
  addCity,
  newAlarm,
  editTime,
  cycleDays,
  toggleSnooze,
  saveDraft,
  deleteDraft,
  pressDial,
  resetTimer,
  stopRing,
  snoozeRing,

  /// The schedule's turn: whatever came due rings (the scheduler's Timer,
  /// and every wake from a sleep).
  check,
}

/// A tab chosen.
final class ClockOpenTab implements ClockAction {
  const ClockOpenTab(this.tab);
  final ClockTab tab;
}

/// A zone picked on the zones screen.
final class ClockPickZone implements ClockAction {
  const ClockPickZone(this.zone);
  final String zone;
}

/// A world city removed (after its confirm).
final class ClockRemoveCity implements ClockAction {
  const ClockRemoveCity(this.index);
  final int index;
}

/// An alarm opened in the editor.
final class ClockEditAlarm implements ClockAction {
  const ClockEditAlarm(this.index);
  final int index;
}

/// An alarm's bell switched.
final class ClockToggleAlarm implements ClockAction {
  const ClockToggleAlarm(this.index);
  final int index;
}

/// An alarm removed (after its confirm).
final class ClockRemoveAlarm implements ClockAction {
  const ClockRemoveAlarm(this.index);
  final int index;
}

/// A home app switched every alarm on or off: Matter's On/Off on Clock's
/// endpoint, as the intents vrx.clock.alarm.arm and .disarm (plan 0015 D7).
final class ClockArmAlarms implements ClockAction {
  const ClockArmAlarms(this.on);
  final bool on;
}

/// The editor's time set.
final class ClockDraftTime implements ClockAction {
  const ClockDraftTime(this.minutes);
  final int minutes;
}

/// The timer's mode switched.
final class ClockTimerMode implements ClockAction {
  const ClockTimerMode(this.mode);
  final TimerMode mode;
}

/// A pomodoro stop picked on the dial.
final class ClockPickDial implements ClockAction {
  const ClockPickDial(this.index);
  final int index;
}

/// The precise dial's minutes set.
final class ClockPrecise implements ClockAction {
  const ClockPrecise(this.minutes);
  final int minutes;
}

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

  /// Times in 12-hour form (the system's locale, VrxTimeFormat).
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

  /// The system's locale says 12-hour (VrxTimeFormat, plan 0011 D7).
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

  // the book changed and wants writing to its file: the applet's effect
  // takes it after the reduce
  bool _saveDue = false;

  void _book(void Function() change) {
    change();
    _saveDue = true;
  }

  /// The book changed since the last call: save it (the applet's effect,
  /// after a reduce).
  bool takeSave() {
    final due = _saveDue;
    _saveDue = false;
    return due;
  }

  void _push(ClockScreen s) => _stack.add(s);
  void _toTabs() => _stack
    ..clear()
    ..add(ClockScreen.tabs);

  void _openTab(ClockTab t) {
    if (ring == null && screen == ClockScreen.tabs) tab = t;
  }

  // ── zones ──────────────────────────────────────────────────────────

  /// The face's zone row: choose the home zone (the system's).
  void _pickHomeZone() {
    if (ring != null || screen != ClockScreen.tabs) return;
    pickHome = true;
    _push(ClockScreen.zones);
  }

  void _addCity() {
    if (ring != null || screen != ClockScreen.tabs || book.world.length >= worldMax) return;
    pickHome = false;
    _push(ClockScreen.zones);
  }

  /// A zone was picked: a world city joins the list; the home zone the
  /// caller sets through timedated. Back to the tabs either way.
  void _pickZone(String zone) {
    if (screen != ClockScreen.zones) return;
    if (!pickHome && !book.world.contains(zone) && book.world.length < worldMax) book.world.add(zone);
    _toTabs();
  }

  void _removeCity(int i) {
    if (i >= 0 && i < book.world.length) book.world.removeAt(i);
  }

  // ── alarms ─────────────────────────────────────────────────────────

  void _newAlarm() {
    if (ring != null || screen != ClockScreen.tabs || book.alarms.length >= alarmsMax) return;
    draft = const Alarm(minutes: 7 * 60); // the alarm most people set
    editing = -1;
    notice = '';
    _push(ClockScreen.editor);
  }

  void _editAlarm(int i) {
    if (ring != null || screen != ClockScreen.tabs || i < 0 || i >= book.alarms.length) return;
    editing = i;
    draft = book.alarms[i]; // a copy: the book may change under an edit
    notice = '';
    _push(ClockScreen.editor);
  }

  void _toggleAlarm(int i) {
    if (i < 0 || i >= book.alarms.length) return;
    book.alarms[i] = book.alarms[i].copyWith(enabled: !book.alarms[i].enabled);
    // a re-enabled one-off rings at its next time, not at a missed one
    book.checked = now;
  }

  void _armAlarms(bool on) {
    for (var i = 0; i < book.alarms.length; i++) {
      book.alarms[i] = book.alarms[i].copyWith(enabled: on);
    }
    // a re-enabled one-off rings at its next time, not at a missed one
    if (on) book.checked = now;
  }

  void _removeAlarm(int i) {
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

  void _editTime() {
    if (screen == ClockScreen.editor) _push(ClockScreen.editTime);
  }

  void _setDraftTime(int minutes) {
    if (screen != ClockScreen.editTime) return;
    draft = draft.copyWith(minutes: minutes.clamp(0, 1439));
    _stack.removeLast();
  }

  /// Four presets rather than seven checkboxes: these cover what people
  /// set, and seven toggles is seven taps to say "weekdays".
  void _cycleDays() {
    if (screen != ClockScreen.editor) return;
    draft = draft.copyWith(
        days: switch (draft.days) { 0 => daysAll, daysAll => daysWeek, daysWeek => daysWeekend, _ => 0 });
  }

  void _toggleSnooze() {
    if (screen == ClockScreen.editor) draft = draft.copyWith(snooze: !draft.snooze);
  }

  /// Save the draft; stays on the editor and says why when it cannot.
  bool _saveDraft() {
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

  void _deleteDraft() {
    if (screen != ClockScreen.editor || editing < 0) return;
    _removeAlarm(editing);
    editing = -1;
    _stack.removeLast();
  }

  // ── the timer ──────────────────────────────────────────────────────

  bool get _onTimer => ring == null && screen == ClockScreen.tabs && tab == ClockTab.timer;
  bool get running => (book.timerEnd ?? 0) > now;

  void _setMode(TimerMode m) {
    if (_onTimer) mode = m;
  }

  void _pickDial(int i) {
    if (_onTimer && mode == TimerMode.pomodoro && !running && i >= 0 && i < dialMinutes.length) dial = i;
  }

  void _setPrecise(int minutes) {
    if (_onTimer && mode == TimerMode.precise && !running) precise = minutes.clamp(1, preciseMax);
  }

  /// The dial's centre: start what is set, or stop what runs.
  void _pressDial() {
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
  void _resetTimer() {
    if (_onTimer) book.timerEnd = null;
  }

  // ── the ring ───────────────────────────────────────────────────────

  /// Check the schedule; the first thing due rings (one at a time).
  /// True when the book changed and wants saving.
  bool _check() {
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
  void _stopRing() {
    final r = ring;
    if (r == null) return;
    ring = null;
    tab = r.kind == FireKind.timer ? ClockTab.timer : ClockTab.face;
  }

  /// Snooze; on an alarm without snooze, or a timer, it stops: a button
  /// that does nothing reads as broken.
  void _snoozeRing() {
    final r = ring;
    if (r == null) return;
    if (canSnooze) {
      book
        ..snoozeUntil = now + snoozeMinutes * 60
        ..snoozeAlarm = r.index;
    }
    _stopRing();
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

  /// The book is the applet's own file (plan 0013 D4); the snapshot
  /// carries nothing, so restoring it changes nothing.
  @override
  void restore(ClockState snapshot) {}

  @override
  ClockAction get backAction => ClockAction.back;

  @override
  bool get atRoot => screen == ClockScreen.tabs;

  @override
  Object? get fingerprint => [
        book.toJson(),
        home.name,
        world.keys.toList(),
        synced,
        zones,
        tab,
        _stack.toList(),
        pickHome,
        editing,
        draft.toJson(),
        notice,
        mode,
        dial,
        precise,
        ring?.kind,
        ring?.index,
        h12,
      ];

  /// A ring must be seen: it holds the screen on, and the hold wakes a
  /// dark screen (plan 0010 D3). Released when the ring stops, snoozes or
  /// gives up, after which the idle timeout runs in full again.
  @override
  String? get keepsScreenOn => ring != null ? 'an alarm or timer is ringing' : null;

  @override
  ClockView reduce(ClockState state, ClockAction action) {
    if (action case ClockFacts(:final book, :final home, :final synced, :final h12, :final zones, :final world)) {
      if (book != null) this.book = book;
      if (home != null) this.home = home;
      if (synced != null) this.synced = synced;
      if (h12 != null) this.h12 = h12;
      if (zones != null) this.zones = zones;
      if (world != null) this.world.addAll(world);
    }
    if (action == ClockAction.back) back();
    switch (action) {
      case ClockOpenTab(:final tab):
        _openTab(tab);
      case ClockPickZone(:final zone):
        _book(() => _pickZone(zone));
      case ClockRemoveCity(:final index):
        _book(() => _removeCity(index));
      case ClockEditAlarm(:final index):
        _editAlarm(index);
      case ClockToggleAlarm(:final index):
        _book(() => _toggleAlarm(index));
      case ClockRemoveAlarm(:final index):
        _book(() => _removeAlarm(index));
      case ClockArmAlarms(:final on):
        _book(() => _armAlarms(on));
      case ClockDraftTime(:final minutes):
        _setDraftTime(minutes);
      case ClockTimerMode(:final mode):
        _setMode(mode);
      case ClockPickDial(:final index):
        _pickDial(index);
      case ClockPrecise(:final minutes):
        _setPrecise(minutes);
      case ClockDo.pickHomeZone:
        _pickHomeZone();
      case ClockDo.addCity:
        _addCity();
      case ClockDo.newAlarm:
        _newAlarm();
      case ClockDo.editTime:
        _editTime();
      case ClockDo.cycleDays:
        _cycleDays();
      case ClockDo.toggleSnooze:
        _toggleSnooze();
      case ClockDo.saveDraft:
        _book(_saveDraft);
      case ClockDo.deleteDraft:
        _book(_deleteDraft);
      case ClockDo.pressDial:
        _book(_pressDial);
      case ClockDo.resetTimer:
        _book(_resetTimer);
      case ClockDo.stopRing:
        _stopRing();
      case ClockDo.snoozeRing:
        _book(_snoozeRing);
      case ClockDo.check:
        if (_check()) _saveDue = true;
      default:
        break;
    }
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
      // an alarm's label, when it has one, before its days (evrx-rt's list)
      alarms: [
        for (final a in book.alarms)
          (hm(a.minutes, h12: h12), a.label.isEmpty ? describeDays(a.days) : '${a.label} · ${describeDays(a.days)}', a.enabled)
      ],
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
