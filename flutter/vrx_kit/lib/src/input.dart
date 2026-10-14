/// Hands: what the person is using right now, a finger or a mouse and
/// keyboard. A vrx board may have a touch panel, an HDMI monitor with a
/// mouse and keyboard, or both; the UI follows whichever was used last.
///
/// The layout does not change with it (rows keep the 9mm touch minimum,
/// so nothing jumps when a hand moves from the glass to the mouse). What
/// changes: focus and hover show for a mouse and keyboard, the on-screen
/// keyboard steps aside while a physical one types, and Escape or the
/// mouse's back button goes back.
library;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'metrics.dart';
import 'scale.dart';

/// The last input used.
enum VrxHands {
  /// A finger on the panel.
  touch,

  /// A mouse or touchpad pointer.
  pointer,

  /// A physical keyboard.
  keys,
}

/// Back for the screen on top: the newest mounted VrxHeader's back
/// (Escape and the mouse's back button call it).
abstract final class VrxBack {
  static final _stack = <VoidCallback>[];

  /// A header offers its back while it is mounted.
  static void offer(VoidCallback back) => _stack.add(back);

  static void withdraw(VoidCallback back) => _stack.remove(back);

  /// Go back, if a screen offers it. True when one did.
  static bool invoke() {
    if (_stack.isEmpty) return false;
    _stack.last();
    return true;
  }
}

/// Offers [onBack] to [VrxBack] while mounted: what Escape and the
/// mouse's back button do on this screen. VrxHeader wraps itself in one.
class VrxBackOffer extends StatefulWidget {
  const VrxBackOffer({super.key, required this.onBack, required this.child});

  final VoidCallback? onBack;
  final Widget child;

  @override
  State<VrxBackOffer> createState() => _VrxBackOfferState();
}

class _VrxBackOfferState extends State<VrxBackOffer> {
  void _back() => widget.onBack?.call();

  @override
  void initState() {
    super.initState();
    VrxBack.offer(_back);
  }

  @override
  void dispose() {
    VrxBack.withdraw(_back);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The hands in use, for widgets that differ by them.
class VrxHandsScope extends InheritedNotifier<ValueNotifier<VrxHands>> {
  const VrxHandsScope({super.key, required ValueNotifier<VrxHands> hands, required super.child})
      : super(notifier: hands);

  static VrxHands of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<VrxHandsScope>()?.notifier?.value ?? VrxHands.touch;
}

/// The applet root's input watcher (AppletHost installs it): tracks the
/// hands, and turns Escape and the mouse back button into [VrxBack].
class VrxInputRoot extends StatefulWidget {
  const VrxInputRoot({super.key, required this.child});

  final Widget child;

  @override
  State<VrxInputRoot> createState() => _VrxInputRootState();
}

class _VrxInputRootState extends State<VrxInputRoot> {
  final _hands = ValueNotifier(VrxHands.touch);
  final _node = FocusNode(debugLabel: 'vrx root', skipTraversal: true);

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
    // keys reach Escape's binding only from inside this tree: hold focus
    // when nothing below took it (an autofocused field or the terminal
    // keeps its own). A microtask after the frame: a field's autofocus is
    // applied in the focus manager's microtask, queued during the build,
    // so it lands first; claimed straight from the frame callback, the
    // root won and an autofocused field never had focus (no keyboard came
    // up for it, and a physical keyboard typed into nothing)
    WidgetsBinding.instance.addPostFrameCallback((_) => scheduleMicrotask(() {
          if (mounted && !_node.hasFocus) _node.requestFocus();
        }));
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _node.dispose();
    _hands.dispose();
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    if (event is KeyDownEvent) _hands.value = VrxHands.keys;
    return false; // watching, never consuming
  }

  void _onPointer(PointerEvent event) {
    _hands.value = event.kind == PointerDeviceKind.touch ? VrxHands.touch : VrxHands.pointer;
    if (event is PointerDownEvent && event.buttons & kBackMouseButton != 0) VrxBack.invoke();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPointer,
      onPointerHover: (e) {
        if (_hands.value != VrxHands.pointer) _hands.value = VrxHands.pointer;
      },
      child: CallbackShortcuts(
        // only when the focused widget left Escape alone (the terminal
        // sends it to the shell)
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => VrxBack.invoke()},
        child: Focus(
          focusNode: _node,
          child: VrxHandsScope(hands: _hands, child: widget.child),
        ),
      ),
    );
  }
}

/// A vertical swipe on [child]: at least [Gestures.swipeMin] of travel
/// (scaled with the display) at [Gestures.swipeMinPxPerS] or more, along
/// the dominant axis. Taps go through to whatever is under it (the
/// strip's Back), so a swipe and a tap never compete for the same touch.
class VrxSwipe extends StatefulWidget {
  const VrxSwipe({super.key, required this.child, this.onDown, this.onUp});

  final Widget child;
  final VoidCallback? onDown;
  final VoidCallback? onUp;

  @override
  State<VrxSwipe> createState() => _VrxSwipeState();
}

class _VrxSwipeState extends State<VrxSwipe> {
  double _dx = 0, _dy = 0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => _dx = _dy = 0,
      onPanUpdate: (d) {
        _dx += d.delta.dx;
        _dy += d.delta.dy;
      },
      onPanEnd: (d) {
        final travel = Gestures.swipeMin * VrxScale.of(context);
        final speed = d.velocity.pixelsPerSecond.dy;
        // vertical only when it dominates; a sideways drag is not this
        if (_dy.abs() < travel || _dy.abs() <= _dx.abs() || speed.abs() < Gestures.swipeMinPxPerS) return;
        (_dy > 0 ? widget.onDown : widget.onUp)?.call();
      },
      child: widget.child,
    );
  }
}
