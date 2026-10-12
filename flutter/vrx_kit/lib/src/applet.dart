/// The applet base class: a store plus a Flutter view. Everything an
/// applet is lives here — `Applet` in `vrx_kit` is to a vrx applet
/// what `Activity` is to an Android app.
library;

import 'package:flutter/widgets.dart';

import 'store.dart';

/// A vrx applet: a store (model + reducer + view model + effects)
/// plus the Widget that renders the view model.
///
/// The store loop is the only writer of the state; `build` is a pure
/// function of the view model; navigation is vrxhost's (Nav), never
/// the applet's.
abstract class Applet<S, A, V> implements StoreModel<S, A, V> {
  /// Render the view model. Standard Flutter widgets, themed and
  /// constrained by vrx_kit: type roles by meaning from the theme,
  /// Spacing from the scale, colour from the scheme — never literals.
  Widget build(BuildContext context, V view);
}
