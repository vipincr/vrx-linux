/// The applet base class: a store plus a Flutter view. Everything an
/// applet is lives here — `Applet` in `vrx_kit` is to a vrx applet
/// what `Activity` is to an Android app.
library;

import 'dart:async';
import 'dart:io' show File, FileSystemException;

import 'package:flutter/material.dart';

import 'host.dart';
import 'input.dart';
import 'scale.dart';
import 'shell.dart';
import 'settings.dart';
import 'store.dart';
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
  AppletsService.install();
  runApp(AppletHost<S, A, V>(applet: applet, actions: actions));
}

/// The colours this boot draws with (plan 0009 D4, D5): the display class
/// the image declares and the scheme and polarity snapshotted at boot, so
/// a scheme chosen in Settings shows on every applet at the next boot and
/// on none before. Anything absent or malformed is the default.
VrxColors bootColors({
  String classFile = '/usr/lib/vrx/display-class',
  String themeFile = '/run/vrx/theme.conf',
}) {
  String read(String path) {
    try {
      // vrx-allow: two short files, read once before the first frame
      return File(path).readAsStringSync();
    } on FileSystemException {
      return '';
    }
  }

  final cls = vrxClassNames[read(classFile).trim()] ?? VrxDisplayClass.lcdColour;
  final theme = parseSettings(read(themeFile));
  return VrxColors.resolve(
    displayClass: cls,
    scheme: int.tryParse(theme['scheme'] ?? '') ?? vrxDefaultScheme,
    dark: theme['polarity'] != 'light',
  );
}

/// The applet's root widget: owns the [Store], rebuilds the view on
/// every published view model. `runApplet` mounts it; tests may pump
/// it directly.
class AppletHost<S, A, V> extends StatefulWidget {
  const AppletHost({
    super.key,
    required this.applet,
    this.actions,
    this.colors,
  });

  final Applet<S, A, V> applet;
  final Stream<A>? actions;

  /// The colours; the boot's ([bootColors]) when none are given (tests
  /// and shots pass their own).
  final VrxColors? colors;

  @override
  State<AppletHost<S, A, V>> createState() => _AppletHostState<S, A, V>();
}

class _AppletHostState<S, A, V> extends State<AppletHost<S, A, V>> {
  late final Store<S, A, V> _store = Store<S, A, V>(widget.applet);
  // read once: the scheme changes at the next boot, never under an applet
  late final VrxColors _boot = bootColors();
  StreamSubscription<V>? _views;
  StreamSubscription<A>? _actions;

  @override
  void initState() {
    super.initState();
    _views = _store.views.listen((_) {
      if (mounted) setState(() {});
    });
    _actions = widget.actions?.listen(_store.dispatch);
    VrxShell.listen();
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
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: vrxThemeData(widget.colors ?? _boot),
      scrollBehavior: const VrxScrollBehavior(),
      // dialogs too: the input root wraps the navigator, and the
      // navigator sits below the shell's strip; the scale is the
      // display's, read before the strip takes its share
      builder: (context, child) => VrxScale.install(
        child: VrxInsets(
          child: VrxInputRoot(child: child ?? const SizedBox.shrink()),
        ),
      ),
      home: VrxInput.install(
        child: AppletScope<A>(
          onAction: _store.dispatch,
          child: Builder(
            builder: (context) => widget.applet.build(context, _store.view),
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
