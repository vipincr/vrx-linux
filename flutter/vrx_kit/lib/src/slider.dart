/// A slider: a whole number between [VrxSlider.min] and [VrxSlider.max],
/// set by a drag along it, a tap where it should be, the arrow keys or a
/// mouse wheel (the key form every drag has). The design system's rules:
///
/// - as tall as the touch minimum, the track inset by half the thumb so
///   the thumb reaches both ends without leaving the control;
/// - press feedback at once, never eased: on a lit panel the class's
///   state layer over the control, on a grey one the thumb inverts (a
///   filled thumb under a filled layer would show nothing);
/// - the focus ring is the applet's one (VrxFocusRing), drawn over the
///   control, so layout never moves;
/// - the rest of the track is the outline, which every display class
///   draws (a container slot can equal the page on a grey panel).
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'focus_ring.dart';
import 'metrics.dart';
import 'motion.dart';
import 'scale.dart';
import 'theme.dart';
import 'ui_standard.g.dart';

class VrxSlider extends StatefulWidget {
  const VrxSlider({
    super.key,
    required this.value,
    required this.label,
    this.min = 0,
    this.max = 100,
    this.step = 10,
    this.onChanged,
    this.onChangeEnd,
  }) : assert(max > min && step > 0);

  /// The value shown (the owner's; a drag shows its own until it lands).
  final int value;

  /// What it sets, for a screen reader ("Brightness").
  final String label;
  final int min, max;

  /// What one key press or wheel click moves it by.
  final int step;

  /// While it moves (a drag): every new value.
  final ValueChanged<int>? onChanged;

  /// Where it came to rest: the end of a drag, a tap, a key, a wheel click.
  final ValueChanged<int>? onChangeEnd;

  @override
  State<VrxSlider> createState() => _VrxSliderState();
}

class _StepIntent extends Intent {
  const _StepIntent(this.by);

  /// Steps, or ±1000 for the ends.
  final int by;
}

class _VrxSliderState extends State<VrxSlider> with SingleTickerProviderStateMixin {
  int? _moving;
  // micro.handle: the handle follows a finger directly, and a step by key, a
  // tap or a wheel click glides it to the new value on effects; the value a
  // screen reader hears does not ease. The unit is a fraction of a track.
  late final VrxSpringValue _pos = VrxSpringValue(vsync: this, value: _fraction, unit: VrxUnit.fractionOf(200));
  double get _fraction => (_shown - widget.min) / (widget.max - widget.min);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _pos.mode = VrxMotion.of(context);
  }

  @override
  void dispose() {
    _pos.dispose();
    super.dispose();
  }

  // the handle goes where the value is: at once under a finger, gliding
  // otherwise
  void _follow() {
    if (_held) {
      _pos.jumpTo(_fraction);
    } else {
      _pos.springTo(_fraction, VrxSpring.micro(VrxMicro.handle));
    }
  }

  bool _held = false, _hovered = false;
  Offset _down = Offset.zero;

  bool get _enabled => widget.onChanged != null || widget.onChangeEnd != null;
  int get _shown => _moving ?? widget.value.clamp(widget.min, widget.max);

  @override
  void didUpdateWidget(VrxSlider old) {
    super.didUpdateWidget(old);
    // the owner caught up with the drag: show the owner's again
    if (_moving != null && !_held && widget.value != old.value) _moving = null;
    _follow();
  }

  int _at(double dx, double width, double pad) {
    final span = width - 2 * pad;
    final f = span <= 0 ? 0.0 : ((dx - pad) / span).clamp(0.0, 1.0);
    return (widget.min + f * (widget.max - widget.min)).round();
  }

  void _move(int v) {
    if (v == _shown) return;
    setState(() => _moving = v);
    _follow();
    widget.onChanged?.call(v);
  }

  void _rest(int v) {
    setState(() {
      _held = false;
      _moving = v == widget.value ? null : v;
    });
    _follow();
    widget.onChangeEnd?.call(v);
  }

  void _step(int by) {
    final v = by.abs() >= 1000
        ? (by > 0 ? widget.max : widget.min)
        : (_shown + by * widget.step).clamp(widget.min, widget.max);
    if (v != _shown) _rest(v);
  }

  @override
  Widget build(BuildContext context) {
    final colors = VrxTheme.of(context);
    final s = ScaledSpacing.of(context);
    final height = s.touch;
    final thumb = height * 0.5;
    final pad = s.inset > thumb / 2 ? s.inset : thumb / 2;
    final layer = colors.classRow.pressedLayerPermille;
    return Semantics(
      slider: true,
      label: widget.label,
      value: '$_shown',
      increasedValue: '${(_shown + widget.step).clamp(widget.min, widget.max)}',
      decreasedValue: '${(_shown - widget.step).clamp(widget.min, widget.max)}',
      onIncrease: _enabled ? () => _step(1) : null,
      onDecrease: _enabled ? () => _step(-1) : null,
      child: FocusableActionDetector(
        enabled: _enabled,
        mouseCursor: _enabled ? SystemMouseCursors.click : MouseCursor.defer,
        onShowFocusHighlight: (v) => VrxFocusRing.report(context, focused: v),
        onShowHoverHighlight: (v) => setState(() => _hovered = v),
        // left and right only: up and down stay the list's, to move focus on
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.arrowLeft): _StepIntent(-1),
          SingleActivator(LogicalKeyboardKey.arrowRight): _StepIntent(1),
          SingleActivator(LogicalKeyboardKey.pageDown): _StepIntent(-3),
          SingleActivator(LogicalKeyboardKey.pageUp): _StepIntent(3),
          SingleActivator(LogicalKeyboardKey.home): _StepIntent(-1000),
          SingleActivator(LogicalKeyboardKey.end): _StepIntent(1000),
        },
        actions: {
          _StepIntent: CallbackAction<_StepIntent>(onInvoke: (i) {
            _step(i.by);
            return null;
          }),
        },
        child: LayoutBuilder(builder: (context, box) {
          final width = box.maxWidth;
          return Listener(
            onPointerSignal: (event) {
              if (!_enabled || event is! PointerScrollEvent) return;
              GestureBinding.instance.pointerSignalResolver.register(event, (e) {
                final dy = (e as PointerScrollEvent).scrollDelta.dy;
                if (dy != 0) _step(dy > 0 ? -1 : 1);
              });
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: _enabled
                  ? (d) => setState(() {
                        _held = true;
                        _down = d.localPosition;
                      })
                  : null,
              onTapCancel: () => setState(() => _held = false),
              onTap: _enabled ? () => _rest(_at(_down.dx, width, pad)) : null,
              onHorizontalDragStart: _enabled
                  ? (d) {
                      setState(() => _held = true);
                      _move(_at(d.localPosition.dx, width, pad));
                    }
                  : null,
              onHorizontalDragUpdate: _enabled ? (d) => _move(_at(d.localPosition.dx, width, pad)) : null,
              onHorizontalDragEnd: _enabled ? (_) => _rest(_shown) : null,
              onHorizontalDragCancel: () => setState(() => _held = false),
              child: SizedBox(
                width: width,
                height: height,
                child: ListenableBuilder(
                  listenable: _pos,
                  builder: (context, _) => CustomPaint(
                  painter: _SliderPainter(
                    fraction: _pos.value,
                    pad: pad,
                    thumb: thumb,
                    track: s.xs,
                    fill: colors.primary,
                    rest: colors.outline,
                    onFill: colors.onPrimary,
                    // a grey panel: the thumb inverts while held
                    inverted: _held && layer == 0,
                    pressLayer: _held && layer > 0 ? colors.primary.withValues(alpha: layer / 1000) : null,
                    hover: _hovered && !_held ? colors.surfaceHigh : null,
                    stroke: Strokes.border,
                  ),
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}

class _SliderPainter extends CustomPainter {
  _SliderPainter({
    required this.fraction,
    required this.pad,
    required this.thumb,
    required this.track,
    required this.fill,
    required this.rest,
    required this.onFill,
    required this.inverted,
    required this.pressLayer,
    required this.hover,
    required this.stroke,
  });

  final double fraction, pad, thumb, track, stroke;
  final Color fill, rest, onFill;
  final bool inverted;
  final Color? pressLayer, hover;

  @override
  void paint(Canvas canvas, Size size) {
    final whole = Offset.zero & size;
    if (hover != null) canvas.drawRect(whole, Paint()..color = hover!);
    final y = size.height / 2;
    final x = pad + fraction.clamp(0.0, 1.0) * (size.width - 2 * pad);
    final half = track / 2;
    canvas.drawRect(Rect.fromLTRB(x, y - half, size.width - pad, y + half), Paint()..color = rest);
    canvas.drawRect(Rect.fromLTRB(pad, y - half, x, y + half), Paint()..color = fill);
    final c = Offset(x, y);
    canvas.drawCircle(c, thumb / 2, Paint()..color = inverted ? onFill : fill);
    if (inverted) {
      canvas.drawCircle(c, thumb / 2 - stroke / 2, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = fill);
    }
    if (pressLayer != null) canvas.drawRect(whole, Paint()..color = pressLayer!);
  }

  @override
  bool shouldRepaint(_SliderPainter old) =>
      old.fraction != fraction ||
      old.inverted != inverted ||
      old.pressLayer != pressLayer ||
      old.hover != hover ||
      old.fill != fill ||
      old.rest != rest ||
      old.pad != pad ||
      old.thumb != thumb;
}
