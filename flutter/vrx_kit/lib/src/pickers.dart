/// Wheels for a time and a date (plan 0011 D14): Clock's picker, moved
/// into the kit so Settings > Time sets the clock with the same control,
/// and the wheel sets the keyboard shows for a date or a time field.
/// A finger drags a wheel; a tap picks a row; a mouse wheel turns it; with
/// it focused, the arrow keys step it. Rows keep the touch minimum.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'components.dart';
import 'motion.dart';
import 'scale.dart';
import 'symbols.dart';
import 'theme.dart';

/// One looping wheel of [count] rows labelled by [label].
class VrxWheel extends StatelessWidget {
  const VrxWheel(
      {super.key, required this.controller, required this.count, required this.label, this.width, this.onChanged});

  final FixedExtentScrollController controller;
  final int count;
  final String Function(int i) label;

  /// The row now chosen (0 to [count] - 1), as the wheel settles on it.
  final void Function(int i)? onChanged;

  /// The wheel's width; two touch minimums when not given.
  final double? width;

  /// Turn [c] to the nearest row showing [i] (the wheels loop), on the
  /// wheel row's spring (plan 0017 D2: no hand-tuned duration).
  void _turnTo(BuildContext context, int i) {
    final now = c.selectedItem;
    var d = i - now % count;
    if (d > count ~/ 2) d -= count;
    if (d < -(count ~/ 2)) d += count;
    unawaited(vrxTurnWheel(c, now + d, itemExtent: ScaledSpacing.of(context).touch, mode: VrxMotion.of(context)));
  }

  FixedExtentScrollController get c => controller;

  @override
  Widget build(BuildContext context) {
    final touch = ScaledSpacing.of(context).touch;
    return Focus(
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
        final step = switch (event.logicalKey) {
          LogicalKeyboardKey.arrowUp => -1,
          LogicalKeyboardKey.arrowDown => 1,
          _ => 0,
        };
        if (step == 0) return KeyEventResult.ignored;
        _turnTo(context, (c.selectedItem + step) % count);
        return KeyEventResult.handled;
      },
      child: SizedBox(
        width: width ?? touch * 2,
        child: ListWheelScrollView.useDelegate(
          controller: c,
          itemExtent: touch,
          // nearly flat: every row a tap can pick keeps the 9mm minimum
          diameterRatio: 40,
          perspective: 0.0001,
          physics: vrxWheelPhysics,
          onSelectedItemChanged: onChanged == null ? null : (i) => onChanged!(i % count),
          childDelegate: ListWheelChildLoopingListDelegate(children: [
            for (var i = 0; i < count; i++)
              VrxPress(
                onTap: () => _turnTo(context, i),
                child: Center(child: Text(label(i), style: TypeRole.title(context))),
              ),
          ]),
        ),
      ),
    );
  }
}

/// The band the chosen row sits in, with the wheels over it.
class VrxWheelBand extends StatelessWidget {
  const VrxWheelBand({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = VrxTheme.of(context);
    final touch = ScaledSpacing.of(context).touch;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: ScaledSpacing.of(context).sm),
      child: Stack(alignment: Alignment.center, children: [
        Container(height: touch, color: colors.surfaceHigh),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: children),
      ]),
    );
  }
}

/// Hour and minute wheels; [read] gives minutes after midnight.
class VrxTimeWheels extends StatelessWidget {
  const VrxTimeWheels({super.key, required this.hours, required this.minutes, this.onChanged});

  final FixedExtentScrollController hours;
  final FixedExtentScrollController minutes;

  /// A wheel moved.
  final VoidCallback? onChanged;

  /// Minutes after midnight, from the two wheels.
  static int read(FixedExtentScrollController hours, FixedExtentScrollController minutes) =>
      (hours.selectedItem % 24) * 60 + minutes.selectedItem % 60;

  @override
  Widget build(BuildContext context) {
    String two(int i) => i.toString().padLeft(2, '0');
    return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      VrxWheel(controller: hours, count: 24, label: two, onChanged: (_) => onChanged?.call()),
      Text(':', style: TypeRole.title(context)),
      VrxWheel(controller: minutes, count: 60, label: two, onChanged: (_) => onChanged?.call()),
    ]);
  }
}

/// Day, month and year wheels; [read] gives the date (a day past the
/// month's end is its last day: 31 February is the 28th or 29th).
class VrxDateWheels extends StatelessWidget {
  const VrxDateWheels({super.key, required this.day, required this.month, required this.year, this.onChanged});

  /// The first year offered; the wheel holds [years] of them.
  static const firstYear = 2024;
  static const years = 40;
  static const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  final FixedExtentScrollController day;
  final FixedExtentScrollController month;
  final FixedExtentScrollController year;

  /// A wheel moved.
  final VoidCallback? onChanged;

  /// The three wheels' controllers, at [date].
  static (FixedExtentScrollController, FixedExtentScrollController, FixedExtentScrollController) at(DateTime date) => (
        FixedExtentScrollController(initialItem: date.day - 1),
        FixedExtentScrollController(initialItem: date.month - 1),
        FixedExtentScrollController(initialItem: (date.year - firstYear).clamp(0, years - 1)),
      );

  static DateTime read(
      FixedExtentScrollController day, FixedExtentScrollController month, FixedExtentScrollController year) {
    final y = firstYear + year.selectedItem % years;
    final m = month.selectedItem % 12 + 1;
    final d = (day.selectedItem % 31 + 1).clamp(1, DateUtils.getDaysInMonth(y, m));
    return DateTime(y, m, d);
  }

  @override
  Widget build(BuildContext context) {
    final gap = ScaledSpacing.of(context).md;
    void moved(int _) => onChanged?.call();
    // three wheels in shares of the width, a gutter apart, so the narrowest
    // panel holds them (the layout check found them touching)
    return Row(children: [
      Expanded(
          flex: 5,
          child: VrxWheel(controller: day, count: 31, label: (i) => '${i + 1}', width: double.infinity, onChanged: moved)),
      SizedBox(width: gap),
      Expanded(
          flex: 5,
          child: VrxWheel(controller: month, count: 12, label: (i) => months[i], width: double.infinity, onChanged: moved)),
      SizedBox(width: gap),
      Expanded(
        flex: 6,
        child: VrxWheel(
            controller: year, count: years, label: (i) => '${firstYear + i}', width: double.infinity, onChanged: moved),
      ),
    ]);
  }
}

/// A time of day: hours and minutes, set with [onSet] as minutes after
/// midnight.
class VrxTimePicker extends StatefulWidget {
  const VrxTimePicker({super.key, this.title = 'Time', required this.minutes, required this.onBack, required this.onSet});

  final String title;
  final int minutes;
  final VoidCallback onBack;
  final void Function(int minutes) onSet;

  @override
  State<VrxTimePicker> createState() => _VrxTimePickerState();
}

class _VrxTimePickerState extends State<VrxTimePicker> {
  late final _hours = FixedExtentScrollController(initialItem: widget.minutes ~/ 60);
  late final _mins = FixedExtentScrollController(initialItem: widget.minutes % 60);

  @override
  void dispose() {
    _hours.dispose();
    _mins.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      VrxHeader(title: widget.title, onBack: widget.onBack),
      Expanded(child: VrxWheelBand(children: [VrxTimeWheels(hours: _hours, minutes: _mins)])),
      VrxRow(glyph: VrxSymbols.check, label: 'Set', onTap: () => widget.onSet(VrxTimeWheels.read(_hours, _mins))),
    ]);
  }
}

/// A date: day, month and year, set with [onSet] (a day past the month's
/// end is its last day: 31 February is the 28th or 29th).
class VrxDatePicker extends StatefulWidget {
  const VrxDatePicker({super.key, this.title = 'Date', required this.date, required this.onBack, required this.onSet});

  final String title;
  final DateTime date;
  final VoidCallback onBack;
  final void Function(DateTime date) onSet;

  @override
  State<VrxDatePicker> createState() => _VrxDatePickerState();
}

class _VrxDatePickerState extends State<VrxDatePicker> {
  late final (FixedExtentScrollController, FixedExtentScrollController, FixedExtentScrollController) _w =
      VrxDateWheels.at(widget.date);

  @override
  void dispose() {
    _w.$1.dispose();
    _w.$2.dispose();
    _w.$3.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      VrxHeader(title: widget.title, onBack: widget.onBack),
      Expanded(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: ScaledSpacing.of(context).inset),
          child: VrxWheelBand(children: [Expanded(child: VrxDateWheels(day: _w.$1, month: _w.$2, year: _w.$3))]),
        ),
      ),
      VrxRow(glyph: VrxSymbols.check, label: 'Set', onTap: () => widget.onSet(VrxDateWheels.read(_w.$1, _w.$2, _w.$3))),
    ]);
  }
}
