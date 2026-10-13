/// The shell's place on screen (plan 0008 D10). The compositor draws the
/// shell applet on an overlay plane above whatever app is focused. Two
/// things cross flutter-vrx's `vrx/shell` and `vrx/insets` channels:
///
/// - every app is told how much of the top the shell's strip covers, and
///   the host lays the app out below it ([VrxInsets]), dialogs included;
/// - the shell says how tall its strip is and whether its drawer has the
///   whole screen ([VrxShellRegion]); the compositor routes input by it;
/// - an app may take the whole screen while a screen of it is up
///   ([VrxNoChrome]): the compositor takes the shell's plane down while
///   that app is focused and its inset is 0.
///
/// Off the board (tests, the host) there is no channel: the inset is 0
/// and a region report goes nowhere.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

class VrxShell {
  VrxShell._();

  static const _shell = MethodChannel('vrx/shell', JSONMethodCodec());
  static const _insets = MethodChannel('vrx/insets', JSONMethodCodec());

  /// The strip's height in device pixels; 0 when no shell runs.
  static final ValueNotifier<double> top = ValueNotifier<double>(0);

  /// A [VrxNoChrome] screen is up: the strip steps aside.
  static final ValueNotifier<bool> hidden = ValueNotifier<bool>(false);
  static final _hiders = <Object>{};

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
    _insets.setMethodCallHandler((call) async {
      if (call.method != 'insets') return;
      pushed = true;
      top.value = _read(call.arguments);
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
      listenable: Listenable.merge([VrxShell.top, VrxShell.hidden]),
      child: child,
      builder: (context, child) {
        // the compositor's 0 follows a hide; the layout need not wait
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
