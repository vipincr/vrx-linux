/// The shell's place on screen (plan 0008 D10). The compositor draws the
/// shell applet on an overlay plane above whatever app is focused. These
/// cross flutter-vrx's `vrx/shell` (calls) and `vrx/chrome` (pushes):
///
/// - every app is told how much of the top the shell's strip covers, and
///   the host lays the app out below it ([VrxInsets]), dialogs included;
/// - the shell says how tall its strip is and whether its drawer has the
///   whole screen ([VrxShellRegion]); the compositor routes input by it;
/// - an app may take the whole screen while a screen of it is up
///   ([VrxNoChrome]): the compositor takes the shell's plane down while
///   that app is focused and its inset is 0;
/// - the strip's Back is the one Back: the compositor hands it to the
///   focused app, which goes back a screen ([VrxBack]) or leaves
///   ([Nav.pop]) at its first. [VrxHeader] draws no arrow of its own
///   while the strip shows.
///
/// Off the board (tests, the host) there is no channel: the inset is 0
/// and a region report goes nowhere.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'input.dart';
import 'metrics.dart';
import 'motion.dart';
import 'nav.dart';
import 'theme.dart';
import 'ui_standard.g.dart';

class VrxShell {
  VrxShell._();

  static const _shell = MethodChannel('vrx/shell', JSONMethodCodec());
  static const _chrome = MethodChannel('vrx/chrome', JSONMethodCodec());

  /// The strip's height in device pixels; 0 when no shell runs.
  static final ValueNotifier<double> top = ValueNotifier<double>(0);

  /// A [VrxNoChrome] screen is up: the strip steps aside.
  static final ValueNotifier<bool> hidden = ValueNotifier<bool>(false);
  static final _hiders = <Object>{};

  /// The strip is over this app now (a shell runs and the app has not
  /// taken the whole screen): its Back is the app's.
  static bool get stripShown => top.value > 0 && !hidden.value;

  /// Notifies when [stripShown] may have changed.
  static final Listenable changes = Listenable.merge([top, hidden]);

  static bool _listening = false;

  static double _read(Object? args) {
    final value = args is Map ? args['top'] : null;
    return value is num && value > 0 ? value.toDouble() : 0;
  }

  /// Follow the inset: pushed on every change, asked once in case the
  /// first push came before Dart was listening.
  static void listen() {
    if (_listening) return;
    _listening = true;
    var pushed = false;
    _chrome.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'insets':
          pushed = true;
          top.value = _read(call.arguments);
        case 'back':
          // the screen on top goes back; at the app's first, the app leaves
          if (!VrxBack.invoke()) unawaited(Nav.pop());
      }
    });
    // a push that lands before the answer is newer than it
    unawaited(_shell.invokeMethod<Object?>('getInsets').then((v) {
      if (!pushed) top.value = _read(v);
    }, onError: (Object _) {}));
  }

  static void _hide(Object who, {required bool on}) {
    on ? _hiders.add(who) : _hiders.remove(who);
    final now = _hiders.isNotEmpty;
    if (now == hidden.value) return;
    hidden.value = now;
    unawaited(_shell.invokeMethod<Object?>('setChrome', {'hidden': now}).then((_) {}, onError: (Object _) {}));
  }

  /// Back to no strip and nothing hiding it: vrx_check, between mounts.
  static void reset() {
    top.value = 0;
    _hiders.clear();
    hidden.value = false;
  }

  /// The strip's Back, from the shell: to the focused app.
  static Future<void> back() async {
    try {
      await _shell.invokeMethod<Object?>('back');
    } on MissingPluginException {
      // off the board
    }
  }

  /// The shell's region: its strip, `top` device pixels from the top, or
  /// the whole screen while its drawer is open.
  static Future<void> setRegion({required double top, required bool full}) async {
    try {
      await _shell.invokeMethod<Object?>('setRegion', {'top': top.round(), 'full': full});
    } on MissingPluginException {
      // off the board
    }
  }
}

/// Lays its child out below the shell's strip and tells it so through
/// MediaQuery (the size it really has). The scale stays the display's:
/// [VrxScale] is installed above this.
class VrxInsets extends StatelessWidget {
  const VrxInsets({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: VrxShell.changes,
      child: child,
      builder: (context, child) {
        // the inset is the strip's height; a screen holding the whole panel
        // is laid out without it
        final px = VrxShell.hidden.value ? 0.0 : VrxShell.top.value;
        if (px <= 0) return child!;
        final media = MediaQuery.of(context);
        final top = px / media.devicePixelRatio;
        return Padding(
          padding: EdgeInsets.only(top: top),
          child: MediaQuery(
            data: media.copyWith(size: Size(media.size.width, media.size.height - top)),
            child: child!,
          ),
        );
      },
    );
  }
}

/// The shell's strip: reports its height (and whether the drawer is
/// open) to the compositor whenever either changes.
class VrxShellRegion extends StatefulWidget {
  const VrxShellRegion({super.key, required this.full, required this.child});

  /// The drawer is open: the shell takes all input.
  final bool full;
  final Widget child;

  @override
  State<VrxShellRegion> createState() => _VrxShellRegionState();
}

class _VrxShellRegionState extends State<VrxShellRegion> {
  double? _sentTop;
  bool? _sentFull;

  void _report() {
    if (!mounted) return;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final top = box.size.height * MediaQuery.of(context).devicePixelRatio;
    if (top == _sentTop && widget.full == _sentFull) return;
    _sentTop = top;
    _sentFull = widget.full;
    unawaited(VrxShell.setRegion(top: top, full: widget.full));
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _report());
    return widget.child;
  }
}

/// While this is mounted the app has the whole screen: the shell's strip
/// steps aside (a keyboard on a panel too short for it and the strip).
class VrxNoChrome extends StatefulWidget {
  const VrxNoChrome({super.key, required this.child});

  final Widget child;

  @override
  State<VrxNoChrome> createState() => _VrxNoChromeState();
}

class _VrxNoChromeState extends State<VrxNoChrome> {
  @override
  void initState() {
    super.initState();
    // after the frame: the insets rebuild what is building now
    WidgetsBinding.instance.addPostFrameCallback((_) => VrxShell._hide(this, on: true));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.addPostFrameCallback((_) => VrxShell._hide(this, on: false));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

// --- the drawer ---------------------------------------------------------------------------------------------------

/// Marks a scrim: the layer under a panel that a tap on closes. It is the
/// whole screen by design, so vrx_check's layout rules do not count it as a
/// control the panel overlaps (its words are still checked, G038).
class VrxScrim extends StatelessWidget {
  const VrxScrim({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// What [VrxPull] hands the strip it builds: whether the drawer is engaged
/// (a finger on it, or any of it on screen), and the wrapper that makes a part
/// of the strip the drawer's handle.
class VrxPullHandle {
  const VrxPullHandle._(this.engaged, this._wrap);

  /// A finger is on the drawer or some of it is on screen, including while it
  /// closes: the shell's region is the whole screen exactly then.
  final bool engaged;
  final Widget Function(Widget child) _wrap;

  /// [child] starts the drawer with a vertical drag.
  Widget handle(Widget child) => _wrap(child);
}

/// The quick drawer's mechanics (plan 0017 D7): it follows the finger 1:1,
/// then flings onto a spring with the finger's velocity, with a rubber band
/// past its end. It owns the drawer's position (one [VrxSpringValue], progress
/// 0 to 1: the only place it lives); the model keeps the intent, said through
/// [onIntent] at release or at a scrim tap, and a change of [open] that is not
/// its own (Back, a restored state) springs it to match.
///
/// Layout: [below] fills the area under the strip, then the drawer's scrim and
/// [panel], then the [strip] on top of both. The panel is laid out once and
/// moved with a transform, so a frame of the drawer repaints one layer.
/// Nothing under motion is ignored: a finger that lands on a moving drawer
/// stops it and takes over (D1), and a tap lands on what is drawn.
class VrxPull extends StatefulWidget {
  const VrxPull({
    super.key,
    required this.open,
    required this.onIntent,
    required this.top,
    required this.strip,
    required this.panel,
    this.below,
    this.scrimLabel = 'Close the drawer',
  });

  /// The drawer is open, as the model says.
  final bool open;

  /// The drawer was let go open (true) or shut (false), or its scrim was tapped.
  final ValueChanged<bool> onIntent;

  /// Where the drawer's layer starts, in logical pixels: the strip's height.
  final double top;

  /// The strip, given the handle and whether the drawer is engaged.
  final Widget Function(BuildContext context, VrxPullHandle pull) strip;

  /// The panel the drawer pulls down.
  final Widget panel;

  /// What fills the area under the strip when the drawer is not over it.
  final Widget? below;

  /// The scrim's words, which a walk finds it by (G038).
  final String scrimLabel;

  /// How far past its stop the panel may travel under a finger, in logical
  /// pixels: the surface is drawn this much taller than its content, so the
  /// overshoot never shows a gap.
  static const skirt = 40.0;

  @override
  State<VrxPull> createState() => _VrxPullState();
}

class _VrxPullState extends State<VrxPull> with TickerProviderStateMixin {
  // a drawer's travel is about 300 px: the unit sets the tolerance of progress
  late final VrxSpringValue _p = VrxSpringValue(vsync: this, value: widget.open ? 1 : 0, unit: VrxUnit.fractionOf(300));
  late final VrxSpringValue _scrim = VrxSpringValue(vsync: this, value: widget.open ? 1 : 0, unit: VrxUnit.alpha);
  late bool _intent = widget.open;
  bool _finger = false;
  bool _lastEngaged = false;
  // where the finger has taken it from, in progress; and how far it has gone,
  // in pixels from where it touched down (DragStartBehavior.down counts the
  // slop too, so the drawer is under the finger and not behind it)
  double _from = 0;
  double _dragged = 0;
  final _panel = GlobalKey();

  // the target counts: an opening spring starts at 0, and a closing one is
  // engaged until its last pixel. (isAnimating cannot say: it is still true on
  // the tick that lands.)
  bool get _engaged => _finger || _p.value > 0 || _p.target > 0;

  @override
  void initState() {
    super.initState();
    _lastEngaged = _engaged;
    _p.addListener(_sync);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final mode = VrxMotion.of(context);
    _p.mode = mode;
    _scrim.mode = mode;
  }

  // the region follows `engaged`: a rebuild when it turns
  void _sync() {
    final now = _engaged;
    if (now != _lastEngaged && mounted) setState(() => _lastEngaged = now);
  }

  @override
  void didUpdateWidget(VrxPull old) {
    super.didUpdateWidget(old);
    // a change the model made (Back, a restore): the drawer goes there; one
    // this widget made itself is already where it is going
    if (widget.open != _intent) {
      _intent = widget.open;
      _finger = false;
      _go(widget.open, velocity: null);
    }
  }

  @override
  void dispose() {
    _p.dispose();
    _scrim.dispose();
    super.dispose();
  }

  // the panel's height, as last measured (the first pull has none, and takes
  // a drawer's typical 300 px for the one frame before the panel is laid out)
  double? _measured;
  double get _height {
    final now = _panel.currentContext?.size?.height;
    if (now != null && now > 0) _measured = now;
    return _measured ?? 300;
  }

  void _go(bool open, {double? velocity}) {
    _p.springTo(open ? 1 : 0, VrxSpring.micro(open ? VrxMicro.drawerOpen : VrxMicro.drawerClose), velocity: velocity);
    _scrim.springTo(open ? 1 : 0, VrxSpring.micro(open ? VrxMicro.drawerOpen : VrxMicro.drawerClose, follow: true));
    _sync();
  }

  void _finish(bool open, {double? velocity}) {
    _finger = false;
    _go(open, velocity: velocity == null ? null : velocity / _height);
    if (open != _intent) {
      _intent = open;
      widget.onIntent(open);
    }
  }

  // a finger lands: the drawer stops where it is and the finger has it (D1)
  void _down() {
    if (_p.isAnimating) {
      _p.stop();
      _scrim.stop();
    }
  }

  // a touch that was no drag (a tap on the panel) lets a stopped drawer go on
  void _up() {
    if (_finger || _p.isAnimating) return;
    final to = _intent ? 1.0 : 0.0;
    if (_p.value != to) _go(_intent);
  }

  void _start(DragStartDetails d) {
    _p.stop();
    _scrim.stop();
    _finger = true;
    _from = _p.value;
    _dragged = 0;
    _sync();
  }

  void _update(DragUpdateDetails d) {
    _dragged += d.primaryDelta ?? d.delta.dy;
    _apply();
    // the panel is not laid out until the first moved pixel has mounted the
    // layer: its height (this position's unit) is known a frame later
    if (_panel.currentContext == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _finger) _apply();
      });
    }
  }

  // the position under the finger: 1:1 to its stop, Flutter's own friction past
  // it (to the skirt at most), clamped above 0
  void _apply() {
    final h = _height;
    final pos = _from + _dragged / h;
    final double shown;
    if (pos > 1) {
      shown = 1 + math.min(vrxRubberBand((pos - 1) * h, h), VrxPull.skirt) / h;
    } else {
      shown = math.max(0, pos);
    }
    _p.jumpTo(shown);
    _scrim.jumpTo(shown.clamp(0.0, 1.0));
  }

  void _end(DragEndDetails d) {
    final v = d.velocity.pixelsPerSecond.dy;
    final fast = v.abs() >= Gestures.swipeMinPxPerS;
    _finish(fast ? v > 0 : _p.value > 0.5, velocity: v);
  }

  void _cancel() => _finish(_p.value > 0.5);

  Widget _drag({required Widget child}) => Listener(
        onPointerDown: (_) => _down(),
        onPointerUp: (_) => _up(),
        onPointerCancel: (_) => _up(),
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          dragStartBehavior: DragStartBehavior.down,
          onVerticalDragStart: _start,
          onVerticalDragUpdate: _update,
          onVerticalDragEnd: _end,
          onVerticalDragCancel: _cancel,
          child: child,
        ),
      );

  // The stack's children come and go while a finger is on the glass (the
  // engaged layer mounts on the first drag update, `below` on the power
  // menu). Without keys an inserted child shifts every later element's
  // index, and Flutter matches positionally: the strip's element is torn
  // down and rebuilt one slot over, which disposes its drag recognizer
  // mid-gesture — the drag went silent after its start, and the drawer's
  // first slow swipe died there (the owner's two-swipe bug; a flick that
  // finished inside one frame survived, which is why the second swipe
  // worked). The keys let the elements MOVE instead of being replaced,
  // so the contact that started on the strip keeps its recognizer to the
  // release (the start of a contact owns its whole life).
  final _belowKey = GlobalKey();
  final _layerKey = GlobalKey();
  final _stripKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final colors = VrxTheme.of(context);
    final pull = VrxPullHandle._(_engaged, (child) => _drag(child: child));
    return Stack(children: [
      if (widget.below != null)
        Positioned(
            key: _belowKey, left: 0, right: 0, top: widget.top, bottom: 0, child: widget.below!),
      if (_engaged)
        Positioned(
          key: _layerKey,
          left: 0,
          right: 0,
          top: widget.top,
          bottom: 0,
          child: _drag(
            child: Stack(clipBehavior: Clip.none, children: [
              // the scrim: a tap closes. A sibling of the panel, so its words
              // stay its own; it rides the effects spring with the position
              Positioned.fill(
                child: VrxScrim(
                  child: Semantics(
                    label: widget.scrimLabel,
                    button: true,
                    child: GestureDetector(
                      onTap: () => _finish(false),
                      child: ListenableBuilder(
                        listenable: _scrim,
                        builder: (context, _) =>
                            ColoredBox(color: colors.page.withValues(alpha: 0.6 * _scrim.value.clamp(0.0, 1.0))),
                      ),
                    ),
                  ),
                ),
              ),
              Align(
                alignment: Alignment.topCenter,
                child: ListenableBuilder(
                  listenable: _p,
                  child: RepaintBoundary(
                    key: _panel,
                    child: Stack(clipBehavior: Clip.none, children: [
                      // the surface above the panel, for an overshoot to show
                      Positioned(
                        left: 0,
                        right: 0,
                        top: -VrxPull.skirt,
                        height: VrxPull.skirt,
                        child: ColoredBox(color: colors.surface),
                      ),
                      widget.panel,
                    ]),
                  ),
                  builder: (context, child) =>
                      FractionalTranslation(translation: Offset(0, _p.value - 1), child: child),
                ),
              ),
            ]),
          ),
        ),
      Positioned(
          key: _stripKey, left: 0, right: 0, top: 0, child: widget.strip(context, pull)),
    ]);
  }
}
