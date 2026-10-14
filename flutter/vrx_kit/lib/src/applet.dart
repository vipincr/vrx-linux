/// The applet base class: a store plus a Flutter view. Everything an
/// applet is lives here — `Applet` in `vrx_kit` is to a vrx applet
/// what `Activity` is to an Android app.
library;

import 'dart:async';
import 'dart:io' show File, FileSystemException;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'channel.dart';
import 'components.dart';
import 'focus_ring.dart';
import 'frames.dart';
import 'host.dart';
import 'input.dart';
import 'motion.dart';
import 'nav.dart';
import 'scale.dart';
import 'screen.dart';
import 'shell.dart';
import 'settings.dart';
import 'store.dart';
import 'switch.dart';
import 'text_input.dart';
import 'theme.dart';
import 'ui_standard.g.dart';

/// A vrx applet: a store (model + reducer + view model + effects)
/// plus the Widget that renders the view model.
///
/// The store loop is the only writer of the state; `build` is a pure
/// function of the view model; navigation is vrxhost's (Nav), never
/// the applet's.
abstract class Applet<S, A, V> extends StoreModel<S, A, V> {
  /// Render the view model. Standard Flutter widgets, themed and
  /// constrained by vrx_kit: type roles by meaning from the theme,
  /// Spacing from the scale, colour from the scheme — never literals.
  Widget build(BuildContext context, V view);

  /// The action for being opened at [route] ('' is the root) with
  /// [payload] (plan 0011 D5), or null to stay where it is. A route the
  /// manifest does not declare arrives as '': a renamed screen opens the
  /// root, never nothing. Asked once at start, and on every open while
  /// running when [followsRoutes].
  A? onRoute(String route, Object? payload) => null;

  /// The manifest declares routes and this applet may be opened at one
  /// while it runs (a warm tile, a resident): the kit follows vrxhost's
  /// route events for it.
  bool get followsRoutes => false;
}

/// Run an applet: the entry point of every applet's `main`.
///
/// Installs the vrxhost client when its socket is present (so [Intent]
/// and [Nav] reach vrxhost on a device), starts the store loop, and
/// mounts the view under the vrx theme, scale and input modality.
/// `actions` feeds actions from outside the view (a tick, a registry
/// change) into the same loop the view dispatches into.
void runApplet<S, A, V>(
  Applet<S, A, V> applet, {
  Stream<A>? actions,
}) {
  WidgetsFlutterBinding.ensureInitialized();
  // touch samples aligned to frame time (plan 0017 D12), so a drag that a
  // finger moves 1:1 steps evenly over a panel clocked differently from the
  // display; the offset is the overlay's, measured on the board. Here and not
  // in AppletHost: a test that pumps AppletHost sends its pointer events
  // straight through
  GestureBinding.instance
    ..resamplingEnabled = true
    ..samplingOffset = const Duration(milliseconds: vrxSamplingOffsetMs);
  final host = AppletsService.install();
  Store.keeper ??= LogindScreenKeeper();
  // frame timings while vrxhost's profiling switch is on (plan 0014 D5)
  if (host != null) VrxFrameTimings(host).start();
  runApp(AppletHost<S, A, V>(applet: applet, actions: actions));
}

/// A short file read once before the first frame; '' when absent.
String _bootRead(String path) {
  try {
    // vrx-allow: two short files, read once before the first frame
    return File(path).readAsStringSync();
  } on FileSystemException {
    return '';
  }
}

/// The display class the image declares (`/usr/lib/vrx/display-class`);
/// anything absent or malformed is the colour LCD.
VrxDisplayClass bootClass({String classFile = '/usr/lib/vrx/display-class'}) =>
    vrxClassNames[_bootRead(classFile).trim()] ?? VrxDisplayClass.lcdColour;

/// The colours this boot draws with (plan 0009 D4, D5): the display class
/// the image declares and the scheme and polarity snapshotted at boot, so
/// a scheme chosen in Settings shows on every applet at the next boot and
/// on none before. Anything absent or malformed is the default.
VrxColors bootColors({
  String classFile = '/usr/lib/vrx/display-class',
  String themeFile = '/run/vrx/theme.conf',
}) {
  final theme = parseSettings(_bootRead(themeFile));
  return VrxColors.resolve(
    displayClass: bootClass(classFile: classFile),
    scheme: int.tryParse(theme['scheme'] ?? '') ?? vrxDefaultScheme,
    dark: theme['polarity'] != 'light',
  );
}

/// The motion tier this build has (plan 0017 D5): `/usr/lib/vrx/motion-tier`,
/// which vrx-theme writes from `VRX_UI_MOTION` or the display class (G053:
/// the one file the tier is read from), the class's own when the file is
/// absent.
VrxTier bootTier({
  String tierFile = '/usr/lib/vrx/motion-tier',
  String classFile = '/usr/lib/vrx/display-class',
}) =>
    VrxMotion.tierFrom(_bootRead(tierFile), bootClass(classFile: classFile));

/// The applet's root widget: owns the [Store], rebuilds the view on
/// every published view model. `runApplet` mounts it; tests may pump
/// it directly.
class AppletHost<S, A, V> extends StatefulWidget {
  const AppletHost({
    super.key,
    required this.applet,
    this.actions,
    this.colors,
    this.tier,
    this.screen,
    this.input,
  });

  final Applet<S, A, V> applet;
  final Stream<A>? actions;

  /// The colours; the boot's ([bootColors]) when none are given (tests
  /// and shots pass their own).
  final VrxColors? colors;

  /// The motion tier; the build's ([bootTier]) when null (tests and shots
  /// pass their own).
  final VrxTier? tier;

  /// Where the input facts and the keyboard mode are read (plan 0013 D6,
  /// D7); the board's when null (tests pass their own).
  final ScreenSettings? screen;

  /// The input facts, given instead of read (vrx_check lays an applet out
  /// with each display's own, plan 0013 D7); read from [screen] when null.
  final VrxInputFacts? input;

  @override
  State<AppletHost<S, A, V>> createState() => _AppletHostState<S, A, V>();
}

class _AppletHostState<S, A, V> extends State<AppletHost<S, A, V>> {
  late final Store<S, A, V> _store = Store<S, A, V>(widget.applet);
  // read once: the scheme changes at the next boot, never under an applet
  late final VrxColors _boot = bootColors();
  late final VrxTier _tier = widget.tier ?? bootTier();
  StreamSubscription<V>? _views;
  StreamSubscription<A>? _actions;
  late final ScreenSettings _screen = widget.screen ?? ScreenSettings();
  StreamSubscription<VrxInputFacts>? _facts;
  // G034 (plan 0013 D7): the touch floor is the hardware's, as the
  // compositor says it; until it has, a touchscreen is assumed
  VrxInputModality _modality = VrxInputModality.touch;

  @override
  void initState() {
    super.initState();
    final given = widget.input;
    if (given != null) {
      _modality = given.touch ? VrxInputModality.touch : VrxInputModality.view;
    } else {
      _facts = _screen.inputFacts().listen((f) {
        final m = f.touch ? VrxInputModality.touch : VrxInputModality.view;
        if (mounted && m != _modality) setState(() => _modality = m);
      }, onError: (Object _) {});
    }
    _views = _store.views.listen((_) {
      if (mounted) setState(() {});
    });
    _actions = widget.actions?.listen(_store.dispatch);
    VrxShell.listen();
    _followRoutes();
  }

  StreamSubscription<VrxDelivery>? _routes;

  void _followRoutes() {
    final host = AppletsService.installed;
    if (host == null) return;
    unawaited(host.route().then((r) => _routed(r.route, r.payload), onError: (Object err) {
      debugPrint('vrx: no route from vrxhost: $err');
    }));
    if (!widget.applet.followsRoutes) return;
    _routes = VrxBridge.listen().listen((d) {
      if (d is VrxRouteDelivery) _routed(d.route, d.payload);
    }, onError: (Object _) {});
  }

  void _routed(String route, Object? payload) {
    if (!mounted) return;
    final action = widget.applet.onRoute(route, payload);
    if (action != null) _store.dispatch(action);
  }

  @override
  void dispose() {
    unawaited(_facts?.cancel());
    unawaited(_routes?.cancel());
    // dispose cannot wait; the cancels finish on their own
    unawaited(_actions?.cancel());
    unawaited(_views?.cancel());
    _store.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: vrxThemeData(widget.colors ?? _boot),
      scrollBehavior: const VrxScrollBehavior(),
      // dialogs too: the input root wraps the navigator, and the
      // navigator sits below the shell's strip; the scale is the
      // display's, read before the strip takes its share
      builder: (context, child) => VrxMotionScope(
        tier: _tier,
        child: VrxScale.install(
          child: VrxInsets(
            child: VrxInputRoot(
              child: VrxFocusRing(
                child: _RefusalBand(
                  child: VrxKeyboardHost(settings: _screen, child: child ?? const SizedBox.shrink()),
                ),
              ),
            ),
          ),
        ),
      ),
      // an applet comes to the front with its own entrance (D8); a screen
      // change inside it slides (D6)
      home: VrxEntrance(
        child: VrxInput.install(
          modality: _modality,
          child: AppletScope<A>(
            onAction: _store.dispatch,
            child: VrxSwitch(
              screen: widget.applet.screen,
              depth: widget.applet.depth,
              child: Builder(
                builder: (context) => widget.applet.build(context, _store.view),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A refused navigation, said over whatever screen is up (plan 0011 D2):
/// the sentence stays until the next navigation succeeds or a tap.
class _RefusalBand extends StatelessWidget {
  const _RefusalBand({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      Positioned.fill(child: child),
      Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: ValueListenableBuilder<String?>(
          valueListenable: Nav.refusal,
          builder: (context, sentence, _) => Material(
            type: MaterialType.transparency,
            child: VrxBanner(text: sentence, onTap: Nav.dismiss),
          ),
        ),
      ),
    ]);
  }
}

/// Lets the view dispatch into its store: `AppletScope.dispatch(context,
/// action)` from any widget under the applet.
class AppletScope<A> extends InheritedWidget {
  const AppletScope({super.key, required this.onAction, required super.child});

  final void Function(A) onAction;

  /// Queue `action` on the nearest applet's store.
  static void dispatch<A>(BuildContext context, A action) {
    final scope = context.getInheritedWidgetOfExactType<AppletScope<A>>();
    if (scope == null) {
      throw StateError('AppletScope.dispatch: no applet of action type $A above this widget');
    }
    scope.onAction(action);
  }

  @override
  bool updateShouldNotify(AppletScope<A> oldWidget) => oldWidget.onAction != onAction;
}
