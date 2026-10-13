import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart' hide Intent; // vrx's Intent
import 'package:vrx_kit/vrx_kit.dart';

import 'book.dart';
import 'state.dart';
import 'tz.dart';

final _events = StreamController<ClockAction>();

/// The book lives in the applet's state directory (the unit's HOME).
String get _bookPath => '${Platform.environment['HOME'] ?? '/var/lib/vrx/clock'}/clock.json';

/// The Clock (evrx-rt's, plan 0006, on vrx): the face, world time,
/// alarms, and a pomodoro and a precise timer. It is resident, so it is
/// also the schedule: it rings whatever is in front, through the
/// sys.alarm.ring intent that brings it there.
class ClockApplet extends Applet<ClockState, ClockAction, ClockView> {
  ClockApplet(this.model);

  final ClockModel model;
  bool flash = false;

  @override
  ClockState get initial => model.initial;

  @override
  ClockAction get bootAction => model.bootAction;

  @override
  ClockView reduce(ClockState state, ClockAction action) => model.reduce(state, action);

  @override
  ClockState get snapshot => model.snapshot;

  void _do(void Function() change, {bool save = false}) {
    change();
    if (save) _scheduler?.saveSoon();
    _scheduler?.arm();
    _events.add(ClockAction.changed);
  }

  void _back() {
    if (!model.back()) {
      Nav.pop();
      return;
    }
    _events.add(ClockAction.changed);
  }

  Future<void> _confirm(BuildContext context, String title, String message, String act, VoidCallback onYes) =>
      showDialog<void>(
        context: context,
        builder: (dialog) => VrxConfirm(
          title: title,
          message: message,
          cancelLabel: 'Cancel',
          onCancel: () => Navigator.of(dialog).pop(), // vrx-allow: a dialog's own route, not the trail
          act: VrxModalAction(
            label: act,
            onTap: () {
              Navigator.of(dialog).pop(); // vrx-allow: a dialog's own route, not the trail
              onYes();
            },
          ),
        ),
      );

  void _pick(ClockView view, int i) {
    if (view.screen == ClockScreen.regions) {
      _do(() => model.pickRegion(i));
      return;
    }
    final home = model.pickHome;
    String? zone;
    _do(() => zone = model.pickCity(i), save: !home);
    final picked = zone;
    if (picked == null) return;
    if (home) {
      // the system's zone: timedated changes it, and the watch brings
      // the change back here like any other
      unawaited(VrxSystem.time.setZone(picked).catchError((Object _) {}));
    } else {
      unawaited(_scheduler?.loadWorld());
    }
  }

  @override
  Widget build(BuildContext context, ClockView view) {
    final Widget body;
    if (view.ring) {
      body = _RingScreen(
        view: view,
        flash: flash,
        onStop: () => _do(model.stopRing, save: true),
        onSnooze: () => _do(model.snoozeRing, save: true),
      );
    } else {
      body = switch (view.screen) {
        ClockScreen.tabs => _tabs(context, view),
        ClockScreen.regions || ClockScreen.cities => _Picker(view: view, onBack: _back, onPick: (i) => _pick(view, i)),
        ClockScreen.editor => _Editor(
            view: view,
            onBack: _back,
            onTime: () => _do(model.editTime),
            onDays: () => _do(model.cycleDays),
            onSnooze: () => _do(model.toggleSnooze),
            onSave: () => _do(() => model.saveDraft(), save: true),
            onDelete: () => _do(model.deleteDraft, save: true),
          ),
        ClockScreen.editTime => _TimePicker(
            minutes: view.draft.minutes,
            onBack: _back,
            onSet: (m) => _do(() => model.setDraftTime(m)),
          ),
      };
    }
    return Scaffold(body: SafeArea(child: body));
  }

  Widget _tabs(BuildContext context, ClockView view) {
    const titles = {
      ClockTab.face: 'Clock',
      ClockTab.world: 'World',
      ClockTab.alarms: 'Alarms',
      ClockTab.timer: 'Timer',
    };
    final Widget content = switch (view.tab) {
      ClockTab.face => _Face(view: view, onZone: () => _do(model.pickHomeZone)),
      ClockTab.world => VrxList(children: [
          if (!view.valid) const _Note('The clock has not been set, so these would all be wrong.'),
          for (var i = 0; i < view.cities.length; i++)
            VrxRow(
              label: view.cities[i].$1,
              value: view.cities[i].$2,
              onLongPress: () => unawaited(_confirm(context, 'Remove this city?',
                  '${view.cities[i].$1} will be taken off the world clock.', 'Remove',
                  () => _do(() => model.removeCity(i), save: true))),
            ),
          if (view.cities.isEmpty) const _Note('No cities yet.'),
          if (view.canAddCity)
            VrxRow(glyph: VrxSymbols.public, label: 'Add a city', onTap: () => _do(model.addCity))
          else
            const _Note('That is six cities, which is all one screen holds.'),
          if (view.cities.isNotEmpty) const _Note('Press and hold a city to remove it.'),
        ]),
      ClockTab.alarms => VrxList(children: [
          for (var i = 0; i < view.alarms.length; i++)
            VrxRow(
              label: view.alarms[i].$1,
              value: view.alarms[i].$2,
              // the bell is the switch and the row is the editor
              valueGlyph: view.alarms[i].$3 ? VrxSymbols.notifications : VrxSymbols.notifications_off,
              onValueGlyph: () => _do(() => model.toggleAlarm(i), save: true),
              onTap: () => _do(() => model.editAlarm(i)),
              onLongPress: () => unawaited(_confirm(context, 'Delete this alarm?',
                  'The ${view.alarms[i].$1} alarm will be deleted.', 'Delete',
                  () => _do(() => model.removeAlarm(i), save: true))),
            ),
          if (view.alarms.isEmpty)
            const _Note('No alarms yet. An alarm brings the clock to the front and lights the screen.'),
          if (view.canAddAlarm)
            VrxRow(glyph: VrxSymbols.alarm, label: 'Add an alarm', onTap: () => _do(model.newAlarm))
          else
            const _Note('That is the most alarms this device holds. Remove one to add another.'),
          if (view.alarms.isNotEmpty) const _Note('Alarms ring while the device is on. Powering it off stops them.'),
        ]),
      ClockTab.timer => _Timer(
          view: view,
          onMode: (m) => _do(() => model.setMode(m)),
          onPick: (i) => _do(() => model.pickDial(i)),
          onPrecise: (m) => _do(() => model.setPrecise(m)),
          onPress: () => _do(model.pressDial, save: true),
          onHold: () => _do(model.resetTimer, save: true),
        ),
    };
    return Column(children: [
      VrxHeader(title: titles[view.tab]!, onBack: Nav.pop),
      Expanded(child: content),
      _TabBar(tab: view.tab, onTab: (t) => _do(() => model.openTab(t))),
    ]);
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final space = ScaledSpacing.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: space.inset, vertical: space.sm),
      child: Text(text, style: TypeRole.caption(context)),
    );
  }
}

/// A face for the time, a globe for other places, a bell for alarms,
/// an hourglass for a countdown.
class _TabBar extends StatelessWidget {
  const _TabBar({required this.tab, required this.onTab});

  final ClockTab tab;
  final void Function(ClockTab) onTab;

  static const _glyphs = [VrxSymbols.schedule, VrxSymbols.public, VrxSymbols.alarm, VrxSymbols.hourglass_empty];

  @override
  Widget build(BuildContext context) {
    final palette = VrxTheme.of(context);
    final touch = ScaledSpacing.of(context).touch;
    return Container(
      decoration: BoxDecoration(border: Border(top: BorderSide(color: palette.line, width: Strokes.hairline))),
      child: Row(children: [
        for (final t in ClockTab.values)
          Expanded(
            child: VrxPress(
              onTap: () => onTab(t),
              child: Container(
                height: touch,
                color: t == tab ? palette.highlight : null,
                child: Icon(_glyphs[t.index], size: touch * 0.5),
              ),
            ),
          ),
      ]),
    );
  }
}

class _Face extends StatelessWidget {
  const _Face({required this.view, required this.onZone});

  final ClockView view;
  final VoidCallback onZone;

  @override
  Widget build(BuildContext context) {
    final space = ScaledSpacing.of(context);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: space.lg),
          // the panel's width at most: a narrow portrait panel fits the
          // digits rather than clipping them
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              view.time,
              style: TypeRole.clock(context).copyWith(
                fontWeight: FontWeight.w300,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
        if (view.valid) Text(view.date, style: TypeRole.subtitle(context)),
        SizedBox(height: space.md),
        if (!view.valid) const _Note('The clock has not been set. Connect to a network to sync it.'),
        VrxRow(label: 'Time zone', value: view.zone.replaceAll('_', ' '), onTap: onZone),
        if (view.next.isNotEmpty) _Note(view.next),
      ],
    );
  }
}

class _Picker extends StatelessWidget {
  const _Picker({required this.view, required this.onBack, required this.onPick});

  final ClockView view;
  final VoidCallback onBack;
  final void Function(int) onPick;

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      VrxHeader(title: view.listTitle, onBack: onBack),
      Expanded(
        child: view.list.isEmpty
            ? const Center(child: CircularProgressIndicator())
            // hundreds of cities: built as they scroll in
            : ListView.builder(
                itemCount: view.list.length,
                itemBuilder: (context, i) => VrxRow(label: view.list[i], value: '', onTap: () => onPick(i)),
              ),
      ),
    ]);
  }
}

class _Editor extends StatelessWidget {
  const _Editor({
    required this.view,
    required this.onBack,
    required this.onTime,
    required this.onDays,
    required this.onSnooze,
    required this.onSave,
    required this.onDelete,
  });

  final ClockView view;
  final VoidCallback onBack, onTime, onDays, onSnooze, onSave, onDelete;

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Expanded(
        child: VrxList(children: [
          VrxHeader(title: view.canDelete ? 'Alarm' : 'New alarm', onBack: onBack),
          VrxRow(label: 'Time', value: hm(view.draft.minutes), onTap: onTime),
          VrxRow(label: 'Repeat', value: describeDays(view.draft.days), onTap: onDays),
          VrxRow(label: 'Snooze', value: view.draft.snooze ? 'On' : 'Off', onTap: onSnooze),
          VrxRow(glyph: VrxSymbols.check, label: 'Save', onTap: onSave),
          if (view.canDelete) VrxRow(glyph: VrxSymbols.delete, label: 'Delete this alarm', onTap: onDelete),
        ]),
      ),
      if (view.notice.isNotEmpty) VrxBanner(text: view.notice),
    ]);
  }
}

/// Hours and minutes on two wheels, each row the touch minimum.
class _TimePicker extends StatefulWidget {
  const _TimePicker({required this.minutes, required this.onBack, required this.onSet});

  final int minutes;
  final VoidCallback onBack;
  final void Function(int) onSet;

  @override
  State<_TimePicker> createState() => _TimePickerState();
}

class _TimePickerState extends State<_TimePicker> {
  late final _hours = FixedExtentScrollController(initialItem: widget.minutes ~/ 60);
  late final _mins = FixedExtentScrollController(initialItem: widget.minutes % 60);

  @override
  void dispose() {
    _hours.dispose();
    _mins.dispose();
    super.dispose();
  }

  Widget _wheel(FixedExtentScrollController c, int count) {
    final touch = ScaledSpacing.of(context).touch;
    return SizedBox(
      width: touch * 2,
      child: ListWheelScrollView.useDelegate(
        controller: c,
        itemExtent: touch,
        physics: const FixedExtentScrollPhysics(),
        childDelegate: ListWheelChildLoopingListDelegate(children: [
          for (var i = 0; i < count; i++)
            Center(child: Text(i.toString().padLeft(2, '0'), style: TypeRole.title(context))),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = VrxTheme.of(context);
    final touch = ScaledSpacing.of(context).touch;
    return Column(children: [
      VrxHeader(title: 'Time', onBack: widget.onBack),
      Expanded(
        child: Stack(alignment: Alignment.center, children: [
          // the band the chosen row sits in
          Container(height: touch, color: palette.highlight),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            _wheel(_hours, 24),
            Text(':', style: TypeRole.title(context)),
            _wheel(_mins, 60),
          ]),
        ]),
      ),
      VrxRow(
        glyph: VrxSymbols.check,
        label: 'Set',
        onTap: () => widget.onSet((_hours.selectedItem % 24) * 60 + _mins.selectedItem % 60),
      ),
    ]);
  }
}

class _Timer extends StatelessWidget {
  const _Timer({
    required this.view,
    required this.onMode,
    required this.onPick,
    required this.onPrecise,
    required this.onPress,
    required this.onHold,
  });

  final ClockView view;
  final void Function(TimerMode) onMode;
  final void Function(int) onPick;
  final void Function(int) onPrecise;
  final VoidCallback onPress, onHold;

  @override
  Widget build(BuildContext context) {
    final space = ScaledSpacing.of(context);
    return Column(children: [
      Padding(
        padding: EdgeInsets.all(space.sm),
        child: VrxSegmented(
          labels: const ['Pomodoro', 'Precise'],
          selected: view.mode.index,
          onSelected: (i) => onMode(TimerMode.values[i]),
        ),
      ),
      Expanded(
        child: Padding(
          padding: EdgeInsets.all(space.sm),
          child: LayoutBuilder(builder: (context, box) {
            final size = math.min(box.maxWidth, box.maxHeight);
            return Center(
              child: SizedBox.square(
                dimension: size,
                child: _Dial(
                  view: view,
                  size: size,
                  onPick: onPick,
                  onPrecise: onPrecise,
                  onPress: onPress,
                  onHold: onHold,
                ),
              ),
            );
          }),
        ),
      ),
    ]);
  }
}

/// The timer's dial. Pomodoro: five stops round it, tap one. Precise:
/// sixty ticks, drag round it to set the minutes. The centre starts
/// and stops; a hold resets.
class _Dial extends StatelessWidget {
  const _Dial({
    required this.view,
    required this.size,
    required this.onPick,
    required this.onPrecise,
    required this.onPress,
    required this.onHold,
  });

  final ClockView view;
  final double size;
  final void Function(int) onPick;
  final void Function(int) onPrecise;
  final VoidCallback onPress, onHold;

  /// Minutes 1..60 at a point, clockwise from the top.
  int _minutesAt(Offset p) {
    final c = size / 2;
    var a = math.atan2(p.dx - c, c - p.dy);
    if (a < 0) a += 2 * math.pi;
    final m = (a / (2 * math.pi) * preciseMax).round();
    return m == 0 ? preciseMax : m;
  }

  @override
  Widget build(BuildContext context) {
    final palette = VrxTheme.of(context);
    final touch = ScaledSpacing.of(context).touch;
    final precise = view.mode == TimerMode.precise;
    final radius = size / 2 - touch / 2;
    void drag(Offset p) {
      if (precise && !view.running) onPrecise(_minutesAt(p));
    }

    return GestureDetector(
      onPanStart: (d) => drag(d.localPosition),
      onPanUpdate: (d) => drag(d.localPosition),
      child: Stack(children: [
        Positioned.fill(
          child: CustomPaint(
            painter: _DialPainter(
              precise: precise,
              value: precise ? (view.running ? int.tryParse(view.centre) ?? 0 : view.precise) : 0,
              ring: view.running ? view.ringValue : ringSteps,
              running: view.running,
              line: palette.line,
              fill: palette.fill,
              stroke: Strokes.border,
              inset: touch / 2,
            ),
          ),
        ),
        if (!precise)
          for (var i = 0; i < dialMinutes.length; i++)
            Positioned(
              left: size / 2 + radius * math.sin(i * 2 * math.pi / dialMinutes.length) - touch / 2,
              top: size / 2 - radius * math.cos(i * 2 * math.pi / dialMinutes.length) - touch / 2,
              width: touch,
              height: touch,
              child: VrxPress(
                onTap: () => onPick(i),
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i == view.dial ? palette.fill : palette.page,
                    border: Border.all(color: palette.line, width: Strokes.hairline),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '${dialMinutes[i]}',
                    style: TypeRole.value(context).copyWith(color: i == view.dial ? palette.onFill : palette.text),
                  ),
                ),
              ),
            ),
        Center(
          child: VrxPress(
            onTap: onPress,
            onLongPress: onHold,
            child: SizedBox.square(
              dimension: math.max(touch * 2, size * 0.42),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                // the glyph says what pressing does; the number what is set
                Icon(view.running ? VrxSymbols.stop : VrxSymbols.play_arrow, size: touch * 0.5),
                Text(view.centre, style: TypeRole.display(context)),
                Text(view.running ? 'left' : 'min', style: TypeRole.caption(context)),
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}

class _DialPainter extends CustomPainter {
  _DialPainter({
    required this.precise,
    required this.value,
    required this.ring,
    required this.running,
    required this.line,
    required this.fill,
    required this.stroke,
    required this.inset,
  });

  final bool precise;
  final int value, ring;
  final bool running;
  final Color line, fill;
  final double stroke, inset;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2 - inset;
    final thin = Paint()
      ..color = line
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    final bold = Paint()
      ..color = fill
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = stroke * 2;
    if (precise) {
      // the ticks are the setting: the chosen span filled
      for (var i = 0; i < preciseMax; i++) {
        final a = i * 2 * math.pi / preciseMax;
        final major = i % 5 == 0;
        final inner = r - (major ? inset * 0.6 : inset * 0.35);
        final dir = Offset(math.sin(a), -math.cos(a));
        canvas.drawLine(c + dir * inner, c + dir * r, i < value ? bold : thin);
      }
      return;
    }
    canvas.drawCircle(c, r, thin);
    // no ring until something runs: an empty track round a button nobody
    // pressed reads as a progress bar stuck at zero
    if (running && ring > 0) {
      canvas.drawArc(Rect.fromCircle(center: c, radius: r), -math.pi / 2, 2 * math.pi * ring / ringSteps, false, bold);
    }
  }

  @override
  bool shouldRepaint(_DialPainter old) =>
      old.precise != precise || old.value != value || old.ring != ring || old.running != running || old.fill != fill;
}

class _RingScreen extends StatelessWidget {
  const _RingScreen({required this.view, required this.flash, required this.onStop, required this.onSnooze});

  final ClockView view;
  final bool flash;
  final VoidCallback onStop, onSnooze;

  @override
  Widget build(BuildContext context) {
    final palette = VrxTheme.of(context);
    final space = ScaledSpacing.of(context);
    final touch = space.touch;
    Widget button(IconData glyph, String label, VoidCallback onTap) => Expanded(
          child: VrxPress(
            onTap: onTap,
            child: Container(
              height: touch * 1.5,
              margin: EdgeInsets.all(space.sm),
              decoration: BoxDecoration(border: Border.all(color: palette.line, width: Strokes.border)),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(glyph, size: touch * 0.5),
                SizedBox(width: space.sm),
                Text(label, style: TypeRole.title(context)),
              ]),
            ),
          ),
        );
    // the one screen read from across a room: the whole panel, and it
    // flashes while it rings
    return Container(
      color: flash ? palette.highlight : palette.page,
      padding: EdgeInsets.all(space.inset),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        FittedBox(fit: BoxFit.scaleDown, child: Text(view.time, style: TypeRole.clock(context))),
        Text(view.ringNote, style: TypeRole.title(context)),
        SizedBox(height: space.lg),
        // words on these two: whoever reads this was asleep a second ago
        Row(children: [
          if (view.canSnooze) button(VrxSymbols.snooze, 'Snooze', onSnooze),
          button(VrxSymbols.stop, 'Stop', onStop),
        ]),
        _Note(view.canSnooze ? 'Snooze gives you nine more minutes.' : 'Tap Stop.'),
      ]),
    );
  }
}

/// The clock's effects: the schedule's wake-ups, the book on disk, the
/// zones, and bringing the ring to the front.
class _Scheduler {
  _Scheduler(this.applet);

  final ClockApplet applet;
  ClockModel get model => applet.model;
  Timer? _wake;
  Timer? _flash;
  Future<void> _saving = Future.value();
  String _front = '';

  void saveSoon() {
    _saving = _saving.then((_) => model.book.save(_bookPath)).catchError((Object err) {
      debugPrint('clock: cannot save the book: $err');
    });
  }

  /// Wake at the next minute boundary, the next thing due, or the next
  /// step of a running timer's ring, whichever is first; never later
  /// than a minute, so a wall-clock jump is caught.
  void arm() {
    _wake?.cancel();
    final now = model.now;
    var at = (now ~/ 60 + 1) * 60;
    final due = nextDue(model.book, now, model.home);
    if (due != null && due < at) at = due;
    final end = model.book.timerEnd, total = model.book.timerSeconds;
    if (end != null && end > now && total > 0) {
      // the next instant the ring's step changes
      final step = total / ringSteps;
      final next = (end - ((end - now) / step).floor() * step).ceil();
      if (next > now && next < at) at = next;
    }
    _wake = Timer(Duration(seconds: math.max(1, at - now)), _onWake);
  }

  void _onWake() {
    final wasRinging = model.ring != null;
    if (model.check()) saveSoon();
    if (model.ring != null && !wasRinging) _ring();
    arm();
    _events.add(ClockAction.tick);
  }

  void _ring() {
    // to the front: the intent's handler is this applet, at its ring
    // route (the manifest); vrxhost pushes it
    if (_front != 'clock') {
      unawaited(() async {
        try {
          await Intent.send('sys.alarm.ring', {'kind': model.ring?.kind.name});
        } on Object catch (err) {
          debugPrint('clock: cannot come to the front: $err');
        }
      }());
    }
    unawaited(VrxSystem.power.setLight(true).catchError((Object _) {}));
    _flash?.cancel();
    // 2 Hz for the ring's bounded length: it gives up after ringSeconds
    _flash = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (model.ring != null && model.ringExpired) {
        model.stopRing();
        saveSoon();
      }
      if (model.ring == null) {
        _flash?.cancel();
        applet.flash = false;
      } else {
        applet.flash = !applet.flash;
      }
      _events.add(ClockAction.tick);
    });
  }

  Future<void> loadWorld() async {
    for (final z in model.book.world) {
      model.world[z] ??= await loadZone(z);
    }
    _events.add(ClockAction.changed);
  }

  Future<void> start() async {
    model.book = await ClockBook.load(_bookPath);
    await loadWorld();
    AppletsService.installed?.watch().listen((f) => _front = f.front, onError: (Object _) {});
    VrxSystem.time.watch().listen((t) async {
      if (t.zone != model.home.name) model.home = await loadZone(t.zone);
      model.synced = t.synced;
      arm();
      _events.add(ClockAction.changed);
    }, onError: (Object err) => debugPrint('clock: no time service: $err'));
    try {
      model.zones = await VrxSystem.time.zones();
    } on Object catch (err) {
      debugPrint('clock: no zone list: $err');
    }
    _onWake();
  }
}

_Scheduler? _scheduler;

Future<void> main() async {
  final applet = ClockApplet(ClockModel());
  _scheduler = _Scheduler(applet);
  runApplet(applet, actions: _events.stream);
  await _scheduler!.start();
}
