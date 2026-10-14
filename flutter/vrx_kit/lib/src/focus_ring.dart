/// The focus ring (plan 0017 Part C, micro.focus): one ring for the whole
/// applet, drawn above the content, that moves between controls on the focus
/// row's spring instead of each control drawing its own and one blinking out
/// as the next blinks on. It is what an HDMI keyboard and mouse see; a touch
/// panel has no focus to show.
///
/// A control reports with [VrxFocusRing.report] from its focus highlight
/// callback and draws nothing itself, so layout never moves for it. The ring
/// follows its control through scrolls and presses: after each frame that
/// happens it asks where the control is now (it schedules none of its own).
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'metrics.dart';
import 'motion.dart';
import 'theme.dart';
import 'ui_standard.g.dart';

class VrxFocusRing extends StatefulWidget {
  const VrxFocusRing({super.key, required this.child});

  final Widget child;

  /// The control under [context] has (or has lost) the keyboard's focus.
  /// Nothing happens where no ring is installed.
  static void report(BuildContext context, {required bool focused}) {
    final scope = context.getInheritedWidgetOfExactType<_Scope>();
    final box = context.findRenderObject();
    if (scope == null || box is! RenderBox) return;
    scope.state._report(box, focused: focused);
  }

  @override
  State<VrxFocusRing> createState() => _VrxFocusRingState();
}

class _Scope extends InheritedWidget {
  const _Scope({required this.state, required super.child});

  final _VrxFocusRingState state;

  @override
  bool updateShouldNotify(_Scope old) => false;
}

class _VrxFocusRingState extends State<VrxFocusRing> with TickerProviderStateMixin {
  // the ring's rectangle, each edge on its own spring (px)
  late final _l = VrxSpringValue(vsync: this, value: 0, unit: VrxUnit.px());
  late final _t = VrxSpringValue(vsync: this, value: 0, unit: VrxUnit.px());
  late final _r = VrxSpringValue(vsync: this, value: 0, unit: VrxUnit.px());
  late final _b = VrxSpringValue(vsync: this, value: 0, unit: VrxUnit.px());
  late final _all = Listenable.merge([_l, _t, _r, _b]);
  RenderBox? _on;
  Rect? _goal;
  bool _shown = false;
  bool _armed = false;
  VrxMotionMode _mode = VrxMotionMode.full;

  VrxSpring get _spring => VrxSpring.micro(VrxMicro.focus);

  void _report(RenderBox box, {required bool focused}) => focused ? _take(box) : _drop(box);

  void _take(RenderBox box) {
    _on = box;
    _arm();
    // the first look: this frame, if one is coming; after it the ring only
    // follows frames that happen
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _drop(RenderBox box) {
    if (_on != box) return;
    _on = null;
    // a control that took the focus in the same turn keeps the ring
    scheduleMicrotask(() {
      if (_on != null || !mounted) return;
      setState(() => _shown = false);
    });
  }

  // after each frame that happens, while a control is focused: where is it
  // now? (no frame of its own is asked for: nothing polls)
  void _arm() {
    if (_armed) return;
    _armed = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _armed = false;
      if (!mounted) return;
      _follow();
      if (_on != null) _arm();
    });
  }

  void _follow() {
    final box = _on;
    final me = context.findRenderObject();
    if (box == null || !box.attached || !box.hasSize || me is! RenderBox) return;
    final at = box.localToGlobal(Offset.zero, ancestor: me) & box.size;
    final goal = _goal;
    if (goal != null && (at.left - goal.left).abs() < 1 && (at.top - goal.top).abs() < 1 && (at.right - goal.right).abs() < 1 && (at.bottom - goal.bottom).abs() < 1) {
      return;
    }
    _goal = at;
    if (!_shown) {
      // it appears where the control is
      for (final (v, x) in [(_l, at.left), (_t, at.top), (_r, at.right), (_b, at.bottom)]) {
        v.jumpTo(x);
      }
      setState(() => _shown = true);
      return;
    }
    for (final (v, x) in [(_l, at.left), (_t, at.top), (_r, at.right), (_b, at.bottom)]) {
      v.springTo(x, _spring);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _mode = VrxMotion.of(context);
    for (final v in [_l, _t, _r, _b]) {
      v.mode = _mode;
    }
  }

  @override
  void dispose() {
    for (final v in [_l, _t, _r, _b]) {
      v.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = VrxTheme.of(context);
    return _Scope(
      state: this,
      child: Stack(children: [
        Positioned.fill(child: widget.child),
        if (_shown)
          Positioned.fill(
            // the ring is a drawing over the content; it takes no pointer
            child: IgnorePointer(
              child: CustomPaint(
                painter: _RingPainter(_all, () => Rect.fromLTRB(_l.value, _t.value, _r.value, _b.value), colors.focus, Strokes.border),
              ),
            ),
          ),
      ]),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(Listenable repaint, this.rect, this.colour, this.stroke) : super(repaint: repaint);

  final Rect Function() rect;
  final Color colour;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      rect().deflate(stroke / 2),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = colour,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.colour != colour || old.stroke != stroke;
}
