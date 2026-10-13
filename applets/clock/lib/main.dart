import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart' hide Intent; // vrx's Intent
import 'package:flutter/services.dart';
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

  void _pickZone(String zone) {
    final home = model.pickHome;
    _do(() => model.pickZone(zone), save: !home);
    if (home) {
      // the system's zone: timedated changes it, and the watch brings
      // the change back here like any other
      unawaited(VrxSystem.time.setZone(zone).catchError((Object _) {}));
    } else {
      unawaited(_scheduler?.loadWorld());
    }
  }

  @override
  Widget build(BuildContext context, ClockView view) {
    final Widget body;
    if (view.ring) {
      // a ring is watched, not touched: it holds the screen on (a logind
      // idle inhibitor), and the hold wakes it if it was off (plan 0010
      // D3); released when the ring ends, after which the idle timeout
      // runs in full again
      body = VrxKeepScreenOn(
        why: 'an alarm or timer is ringing',
        child: _RingScreen(
          view: view,
          flash: flash,
          onStop: () => _do(model.stopRing, save: true),
          onSnooze: () => _do(model.snoozeRing, save: true),
        ),
      );
    } else {
      body = switch (view.screen) {
        ClockScreen.tabs => _tabs(context, view),
        ClockScreen.zones => VrxZonePicker(
            title: view.pickHome ? 'Time zone' : 'Add a city',
            zones: view.zones,
            current: view.pickHome ? view.zone : '',
            onBack: _back,
            onPick: _pickZone,
          ),
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
              onLongPress: () => unawaited(_confirm(
                  context,
                  'Remove this city?',
                  '${view.cities[i].$1} will be taken off the world clock.',
                  'Remove',
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
              onLongPress: () => unawaited(_confirm(
                  context,
                  'Delete this alarm?',
                  'The ${view.alarms[i].$1} alarm will be deleted.',
                  'Delete',
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
          onPick: (i) => _do(() => model.pickDial(i)),
          onPrecise: (m) => _do(() => model.setPrecise(m)),
          onPress: () => _do(model.pressDial, save: true),
          onHold: () => _do(model.resetTimer, save: true),
        ),
    };
    final precise = view.mode == TimerMode.precise;
    return Column(children: [
      VrxHeader(
        title: titles[view.tab]!,
        onBack: Nav.pop,
        // the timer's mode, in the header: the dial needs every millimetre
        // of a 58mm panel under the shell's strip
        action: view.tab == ClockTab.timer
            ? VrxChip(
                label: precise ? 'Precise' : 'Pomodoro',
                onTap: view.running
                    ? null
                    : () => _do(() => model.setMode(precise ? TimerMode.pomodoro : TimerMode.precise)),
              )
            : null,
      ),
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
    final colors = VrxTheme.of(context);
    final touch = ScaledSpacing.of(context).touch;
    return Container(
      decoration: BoxDecoration(border: Border(top: BorderSide(color: colors.outlineFaint, width: Strokes.hairline))),
      child: Row(children: [
        for (final t in ClockTab.values)
          Expanded(
            child: VrxPress(
              onTap: () => onTab(t),
              child: Container(
                height: touch,
                color: t == tab ? colors.secondaryContainer : null,
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
      children: [
        // the digits take whatever height the rows below leave, and the
        // panel's width at most: a short panel shrinks them rather than
        // pushing the zone and the next alarm off the screen
        Expanded(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: space.lg, vertical: space.xs),
            child: Center(
              child: FittedBox(
                fit: BoxFit.contain,
                child: Text(
                  view.time,
                  style: TypeRole.clock(context).copyWith(
                    fontWeight: FontWeight.w300,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
          ),
        ),
        if (view.valid) Text(view.date, style: TypeRole.subtitle(context)),
        if (!view.valid) const _Note('The clock has not been set. Connect to a network to sync it.'),
        VrxRow(label: 'Time zone', value: view.zone.replaceAll('_', ' '), onTap: onZone),
        if (view.next.isNotEmpty) _Note(view.next),
      ],
    );
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
          VrxRow(label: 'Time', value: hm(view.draft.minutes, h12: view.h12), onTap: onTime),
          VrxRow(label: 'Repeat', value: describeDays(view.draft.days), onTap: onDays),
          VrxRow(label: 'Snooze', value: view.draft.snooze ? 'On' : 'Off', onTap: onSnooze),
          VrxRow(glyph: VrxSymbols.check, label: 'Save', onTap: onSave),
          if (view.canDelete) VrxRow(glyph: VrxSymbols.delete, label: 'Delete this alarm', onTap: onDelete),
        ]),
      ),
      if (view.notice.isNotEmpty) VrxBanner(text: view.notice, signal: VrxSignal.info),
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

  /// Turn [c] to the nearest row showing [i] (the wheels loop).
  void _turnTo(FixedExtentScrollController c, int count, int i) {
    final now = c.selectedItem;
    var d = i - now % count;
    if (d > count ~/ 2) d -= count;
    if (d < -(count ~/ 2)) d += count;
    unawaited(c.animateToItem(now + d, duration: const Duration(milliseconds: 200), curve: Curves.easeOut));
  }

  Widget _wheel(FixedExtentScrollController c, int count) {
    final touch = ScaledSpacing.of(context).touch;
    // a finger drags it; a tap picks a row; a mouse wheel turns it; with
    // it focused, the arrow keys step it
    return Focus(
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
        final step = switch (event.logicalKey) {
          LogicalKeyboardKey.arrowUp => -1,
          LogicalKeyboardKey.arrowDown => 1,
          _ => 0,
        };
        if (step == 0) return KeyEventResult.ignored;
        _turnTo(c, count, (c.selectedItem + step) % count);
        return KeyEventResult.handled;
      },
      child: SizedBox(
        width: touch * 2,
        child: ListWheelScrollView.useDelegate(
          controller: c,
          itemExtent: touch,
          // nearly flat: every row a tap can pick keeps the 9mm minimum
          diameterRatio: 40,
          perspective: 0.0001,
          physics: const FixedExtentScrollPhysics(),
          childDelegate: ListWheelChildLoopingListDelegate(children: [
            for (var i = 0; i < count; i++)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _turnTo(c, count, i),
                child: Center(child: Text(i.toString().padLeft(2, '0'), style: TypeRole.title(context))),
              ),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = VrxTheme.of(context);
    final touch = ScaledSpacing.of(context).touch;
    return Column(children: [
      VrxHeader(title: 'Time', onBack: widget.onBack),
      Expanded(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: ScaledSpacing.of(context).sm),
          child: Stack(alignment: Alignment.center, children: [
            // the band the chosen row sits in
            Container(height: touch, color: colors.surfaceHigh),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              _wheel(_hours, 24),
              Text(':', style: TypeRole.title(context)),
              _wheel(_mins, 60),
            ]),
          ]),
        ),
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
    required this.onPick,
    required this.onPrecise,
    required this.onPress,
    required this.onHold,
  });

  final ClockView view;
  final void Function(int) onPick;
  final void Function(int) onPrecise;
  final VoidCallback onPress, onHold;

  @override
  Widget build(BuildContext context) {
    final space = ScaledSpacing.of(context);
    return Padding(
      padding: EdgeInsets.all(space.xs),
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
    );
  }
}

/// The timer's dial: one control, as evrx-rt's. The outer band, a touch
/// minimum wide, is the setting: in pomodoro five sectors (tap one), in
/// precise sixty minutes (tap or drag round). The centre starts and
/// stops; a hold on it resets. Focused, the arrows step the setting and
/// Enter presses. One control, so no small stop can sit on the centre.
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

  /// Clockwise from the top, 0..1.
  double _turn(Offset p) {
    var a = math.atan2(p.dx - size / 2, size / 2 - p.dy);
    if (a < 0) a += 2 * math.pi;
    return a / (2 * math.pi);
  }

  bool _inCentre(Offset p, double inner) => (p - Offset(size / 2, size / 2)).distance <= inner;

  void _set(Offset p) {
    if (view.running) return;
    final t = _turn(p);
    if (view.mode == TimerMode.precise) {
      final m = (t * preciseMax).round();
      onPrecise(m == 0 ? preciseMax : m);
    } else {
      onPick((t * dialMinutes.length).round() % dialMinutes.length);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = VrxTheme.of(context);
    final touch = ScaledSpacing.of(context).touch;
    final precise = view.mode == TimerMode.precise;
    final inner = size / 2 - touch;
    final centre = math.max(0.0, 2 * inner - 2 * Strokes.border);
    return Focus(
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
        final key = event.logicalKey;
        if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.space) {
          onPress();
          return KeyEventResult.handled;
        }
        final step = key == LogicalKeyboardKey.arrowRight || key == LogicalKeyboardKey.arrowUp
            ? 1
            : key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.arrowDown
                ? -1
                : 0;
        if (step == 0 || view.running) return KeyEventResult.ignored;
        if (precise) {
          onPrecise((view.precise + step).clamp(1, preciseMax));
        } else {
          onPick((view.dial + step) % dialMinutes.length);
        }
        return KeyEventResult.handled;
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTapUp: (d) => _inCentre(d.localPosition, inner) ? onPress() : _set(d.localPosition),
          onLongPressStart: (d) {
            if (_inCentre(d.localPosition, inner)) onHold();
          },
          onPanStart: precise ? (d) => _set(d.localPosition) : null,
          onPanUpdate: precise ? (d) => _set(d.localPosition) : null,
          child: CustomPaint(
            painter: _DialPainter(
              precise: precise,
              value: precise ? (view.running ? int.tryParse(view.centre) ?? 0 : view.precise) : 0,
              dial: view.dial,
              ring: view.running ? view.ringValue : ringSteps,
              running: view.running,
              band: touch,
              line: colors.outline,
              fill: colors.primary,
              onFill: colors.onPrimary,
              text: colors.text,
              label: TypeRole.value(context),
              stroke: Strokes.border,
            ),
            child: Center(
              child: Container(
                width: centre,
                height: centre,
                decoration: BoxDecoration(shape: BoxShape.circle, color: colors.surfaceHigh),
                padding: EdgeInsets.all(centre * 0.14),
                child: FittedBox(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    // the glyph says what pressing does; the number what is set
                    Icon(view.running ? VrxSymbols.pause : VrxSymbols.play_arrow, size: touch * 0.5),
                    Text(view.centre, style: TypeRole.display(context)),
                    Text(view.running ? 'left' : 'min', style: TypeRole.caption(context)),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DialPainter extends CustomPainter {
  _DialPainter({
    required this.precise,
    required this.value,
    required this.dial,
    required this.ring,
    required this.running,
    required this.band,
    required this.line,
    required this.fill,
    required this.onFill,
    required this.text,
    required this.label,
    required this.stroke,
  });

  final bool precise;
  final int value, dial, ring;
  final bool running;
  final double band, stroke;
  final Color line, fill, onFill, text;
  final TextStyle label;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final outer = size.shortestSide / 2 - stroke;
    final mid = outer - band / 2;
    final thin = Paint()
      ..color = line
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    final bold = Paint()
      ..color = fill
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = stroke * 2;
    Offset at(double turn, double r) => c + Offset(math.sin(turn * 2 * math.pi), -math.cos(turn * 2 * math.pi)) * r;
    if (precise) {
      // the ticks are the setting: the chosen span filled
      for (var i = 0; i < preciseMax; i++) {
        final major = i % 5 == 0;
        final t = i / preciseMax;
        canvas.drawLine(at(t, outer - band * (major ? 0.55 : 0.3)), at(t, outer), i < value ? bold : thin);
      }
      return;
    }
    canvas.drawCircle(c, outer, thin);
    canvas.drawCircle(c, outer - band, thin);
    // no ring until something runs: an empty track round a button nobody
    // pressed reads as a progress bar stuck at zero
    if (running && ring > 0) {
      canvas.drawArc(
          Rect.fromCircle(center: c, radius: outer), -math.pi / 2, 2 * math.pi * ring / ringSteps, false, bold);
    }
    for (var i = 0; i < dialMinutes.length; i++) {
      final p = at(i / dialMinutes.length, mid);
      final chosen = i == dial;
      if (chosen) canvas.drawCircle(p, band * 0.4, Paint()..color = fill);
      final tp = TextPainter(
        text: TextSpan(text: '${dialMinutes[i]}', style: label.copyWith(color: chosen ? onFill : text)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, p - Offset(tp.width / 2, tp.height / 2));
      tp.dispose();
    }
  }

  @override
  bool shouldRepaint(_DialPainter old) =>
      old.precise != precise ||
      old.value != value ||
      old.dial != dial ||
      old.ring != ring ||
      old.running != running ||
      old.fill != fill ||
      old.band != band;
}

class _RingScreen extends StatelessWidget {
  const _RingScreen({required this.view, required this.flash, required this.onStop, required this.onSnooze});

  final ClockView view;
  final bool flash;
  final VoidCallback onStop, onSnooze;

  @override
  Widget build(BuildContext context) {
    final colors = VrxTheme.of(context);
    final space = ScaledSpacing.of(context);
    final touch = space.touch;
    // full width and stacked: side by side, a glyph and a word do not fit
    // half of a 43mm panel
    Widget button(IconData glyph, String label, VoidCallback onTap, {bool strong = false}) => Padding(
          padding: EdgeInsets.only(top: space.sm),
          child: VrxPress(
            onTap: onTap,
            child: Container(
              height: touch * 1.3,
              decoration: BoxDecoration(
                color: strong ? colors.primary : null,
                border: Border.all(color: strong ? colors.primary : colors.outline, width: Strokes.border),
                borderRadius: BorderRadius.circular(Radii.md),
              ),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(glyph, size: touch * 0.45, color: strong ? colors.onPrimary : colors.text),
                SizedBox(width: space.sm),
                Text(label, style: TypeRole.title(context).copyWith(color: strong ? colors.onPrimary : colors.text)),
              ]),
            ),
          ),
        );
    // the one screen read from across a room: the whole panel (the
    // shell's strip steps aside), and it flashes while it rings
    return VrxNoChrome(
      child: Container(
        color: flash ? colors.primaryContainer : colors.page,
        padding: EdgeInsets.all(space.inset),
        child: Column(children: [
          const Spacer(),
          FittedBox(fit: BoxFit.scaleDown, child: Text(view.time, style: TypeRole.clock(context))),
          Text(view.ringNote, style: TypeRole.title(context), textAlign: TextAlign.center),
          const Spacer(),
          // words on these two: whoever reads this was asleep a second ago
          if (view.canSnooze) button(VrxSymbols.snooze, 'Snooze 9 min', onSnooze),
          button(view.ringIsTimer ? VrxSymbols.timer_off : VrxSymbols.alarm_off, 'Stop', onStop, strong: true),
        ]),
      ),
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
    // the 12/24-hour setting (plan 0008 D5), followed as it changes
    AppletSettings().watch('clock').listen((v) {
      model.h12 = v['clock_format'] == '12h';
      _events.add(ClockAction.changed);
    }, onError: (Object err) => debugPrint('clock: no settings file: $err'));
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
