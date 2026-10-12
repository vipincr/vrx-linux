/// The vrx design system: type roles by meaning (never by size), the
/// spacing scale, and the touch minimum.
///
/// Type roles resolve to Flutter's textTheme but carry vrx's meanings;
/// an applet asks for "the screen's own name" (title), not "20px".
///
/// Spacing constants are mm-derived (a 2mm grid at vrx's reference
/// density). xs and xl are the plan's anchors (9px, 52px); the
/// intermediate stops are provisional until checked against evrx-rt's
/// scale — flagged, not silent.
library;

import 'package:flutter/material.dart';

/// The spacing scale. Pick by role: xs hairlines and glyph gaps, sm
/// inside a control, md a control's default margin, lg between
/// groups, xl screen margins.
abstract final class Spacing {
  /// 2mm-class: glyph gaps, list dividers.
  static const double xs = 9.0;

  /// ~3.5mm: padding inside a control.
  static const double sm = 16.0;

  /// ~5mm: a control's default margin.
  static const double md = 24.0;

  /// ~7.5mm: between groups.
  static const double lg = 36.0;

  /// 11mm-class: screen margins, the one big gap.
  static const double xl = 52.0;

  /// The minimum touch target. Provisional (44 vs 48) until confirmed
  /// against evrx-rt's value.
  static const double touch = 48.0;
}

/// Type roles by meaning: the applet names the role, the theme
/// supplies the style. Never a size, never a literal colour.
abstract final class TypeRole {
  /// The one large thing on a screen.
  static TextStyle display(BuildContext context) =>
      Theme.of(context).textTheme.displayLarge!;

  /// The screen's own name.
  static TextStyle title(BuildContext context) =>
      Theme.of(context).textTheme.titleLarge!;

  /// A section within a screen.
  static TextStyle subtitle(BuildContext context) =>
      Theme.of(context).textTheme.titleMedium!;

  /// The part of a sentence that carries it.
  static TextStyle emphasis(BuildContext context) =>
      Theme.of(context).textTheme.titleSmall!;

  /// The default.
  static TextStyle body(BuildContext context) =>
      Theme.of(context).textTheme.bodyLarge!;

  /// A row's primary label.
  static TextStyle list(BuildContext context) =>
      Theme.of(context).textTheme.bodyLarge!;

  /// The reading on the right of a row.
  static TextStyle value(BuildContext context) =>
      Theme.of(context).textTheme.bodyMedium!;

  /// An explanation under a control.
  static TextStyle subtext(BuildContext context) =>
      Theme.of(context).textTheme.bodySmall!;

  /// A unit, timestamp, footnote.
  static TextStyle caption(BuildContext context) =>
      Theme.of(context).textTheme.bodySmall!;
}
