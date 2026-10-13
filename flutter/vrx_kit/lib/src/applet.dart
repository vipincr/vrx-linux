/// The applet base class: a store plus a Flutter view. Everything an
/// applet is lives here — `Applet` in `vrx_kit` is to a vrx applet
/// what `Activity` is to an Android app.
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import 'host.dart';
import 'input.dart';
import 'scale.dart';
import 'store.dart';
import 'theme.dart';

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
  VrxPalette? palette,
}) {
  WidgetsFlutterBinding.ensureInitialized();
  AppletsService.install();
  runApp(AppletHost<S, A, V>(applet: applet, actions: actions, palette: palette));
}

/// The palette the runtime picks when the applet names none: colour,
/// unless the board says its panel is e-paper (VRX_DISPLAY=epaper in
/// the applet's environment, which vrxhost passes through).
VrxPalette defaultPalette() =>
    paletteFor(colour: Platform.environment['VRX_DISPLAY'] != 'epaper');

/// The applet's root widget: owns the [Store], rebuilds the view on
/// every published view model. `runApplet` mounts it; tests may pump
/// it directly.
class AppletHost<S, A, V> extends StatefulWidget {
  const AppletHost({
    super.key,
    required this.applet,
    this.actions,
    this.palette,
  });

  final Applet<S, A, V> applet;
  final Stream<A>? actions;
  final VrxPalette? palette;

  @override
  State<AppletHost<S, A, V>> createState() => _AppletHostState<S, A, V>();
}

class _AppletHostState<S, A, V> extends State<AppletHost<S, A, V>> {
  late final Store<S, A, V> _store = Store<S, A, V>(widget.applet);
  StreamSubscription<V>? _views;
  StreamSubscription<A>? _actions;

  @override
  void initState() {
    super.initState();
    _views = _store.views.listen((_) {
      if (mounted) setState(() {});
    });
    _actions = widget.actions?.listen(_store.dispatch);
  }

  @override
  void dispose() {
    // dispose cannot wait; the cancels finish on their own
    unawaited(_actions?.cancel());
    unawaited(_views?.cancel());
    _store.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = widget.palette ?? defaultPalette();
    return VrxTheme(
      palette: palette,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: vrxThemeData(palette),
        scrollBehavior: const VrxScrollBehavior(),
        // dialogs too: the input root wraps the navigator
        builder: (context, child) => VrxInputRoot(child: child ?? const SizedBox.shrink()),
        home: VrxScale.install(
          child: VrxInput.install(
            child: AppletScope<A>(
              onAction: _store.dispatch,
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
