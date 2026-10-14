/// Wheels for a time and a date (plan 0011 D14): Clock's picker, moved
/// into the kit so Settings > Time sets the clock with the same control.
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
  const VrxWheel({super.key, required this.controller, required this.count, required this.label, this.width});

  final FixedExtentScrollController controller;
  final int count;
  final String Function(int i) label;

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
class _Wheels extends StatelessWidget {
  const _Wheels({required this.children});

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
    String two(int i) => i.toString().padLeft(2, '0');
    return Column(children: [
      VrxHeader(title: widget.title, onBack: widget.onBack),
      Expanded(
        child: _Wheels(children: [
          VrxWheel(controller: _hours, count: 24, label: two),
          Text(':', style: TypeRole.title(context)),
          VrxWheel(controller: _mins, count: 60, label: two),
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

/// A date: day, month and year, set with [onSet] (a day past the month's
/// end is its last day: 31 February is the 28th or 29th).
class VrxDatePicker extends StatefulWidget {
  const VrxDatePicker({super.key, this.title = 'Date', required this.date, required this.onBack, required this.onSet});

  /// The first year offered; the wheel holds [years] of them.
  static const firstYear = 2024;
  static const years = 40;

  final String title;
  final DateTime date;
  final VoidCallback onBack;
  final void Function(DateTime date) onSet;

  @override
  State<VrxDatePicker> createState() => _VrxDatePickerState();
}

class _VrxDatePickerState extends State<VrxDatePicker> {
  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  late final _day = FixedExtentScrollController(initialItem: widget.date.day - 1);
  late final _month = FixedExtentScrollController(initialItem: widget.date.month - 1);
  late final _year = FixedExtentScrollController(
      initialItem: (widget.date.year - VrxDatePicker.firstYear).clamp(0, VrxDatePicker.years - 1));

  @override
  void dispose() {
    _day.dispose();
    _month.dispose();
    _year.dispose();
    super.dispose();
  }

  void _set() {
    final y = VrxDatePicker.firstYear + _year.selectedItem % VrxDatePicker.years;
    final m = _month.selectedItem % 12 + 1;
    final last = DateUtils.getDaysInMonth(y, m);
    final d = (_day.selectedItem % 31 + 1).clamp(1, last);
    widget.onSet(DateTime(y, m, d));
  }

  @override
  Widget build(BuildContext context) {
    final space = ScaledSpacing.of(context);
    return Column(children: [
      VrxHeader(title: widget.title, onBack: widget.onBack),
      Expanded(
        // three wheels in shares of the width, a gutter apart, so the
        // narrowest panel holds them (the layout check found them touching)
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: space.inset),
          child: _Wheels(children: [
            Expanded(flex: 5, child: VrxWheel(controller: _day, count: 31, label: (i) => '${i + 1}', width: double.infinity)),
            SizedBox(width: space.md),
            Expanded(flex: 5, child: VrxWheel(controller: _month, count: 12, label: (i) => _months[i], width: double.infinity)),
            SizedBox(width: space.md),
            Expanded(
              flex: 6,
              child: VrxWheel(
                  controller: _year,
                  count: VrxDatePicker.years,
                  label: (i) => '${VrxDatePicker.firstYear + i}',
                  width: double.infinity),
            ),
          ]),
        ),
      ),
      VrxRow(glyph: VrxSymbols.check, label: 'Set', onTap: _set),
    ]);
  }
}
