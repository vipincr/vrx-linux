/// The vrx design system, ported from evrx-rt's `ui_metrics.h` type
/// scale and `ui_palette.c` — the numbers are the design.
///
/// Type roles by meaning, never by size; roles outnumber sizes on
/// purpose. Sizes are evrx-rt's values in typographic points, snapped
/// as evrx-rt snaps them, and convert to dp through [ptToDp] (a point
/// is 1/72 inch): the type is physically the size evrx-rt draws it.
///
/// Ink roles resolve from the active palette: `paper` (the e-paper
/// lineage, light page) or `dark` (the scanned-panel palette with the
/// product accent). Emphasis is a size step or inversion, never grey
/// text; disabled removes the frame and keeps secondary ink.
library;

import 'package:flutter/material.dart';

import 'metrics.dart';
import 'scale.dart';

/// The type scale. CLOCK renders digits only (`0-9:-`, no fallback
/// face); CODE is monospace; MICRO is subscripts only.
enum VrxTypeRole {
  clock(42.1),
  display(14.5),
  title(12.5),
  iconLarge(12.5),
  subtitle(11.2),
  emphasis(11.2),
  body(9.9),
  list(9.9),
  icon(9.9),
  value(8.5),
  subtext(8.5),
  caption(8.5),
  code(8.5),
  micro(6.6);

  const VrxTypeRole(this.size);

  /// The size in typographic points (evrx-rt's numbers).
  final double size;

  /// The size in logical dp, before the display scale.
  double get dp => size * ptToDp;
}

/// Resolve a role to a style from the active theme's fonts.
abstract final class TypeRole {
  static TextStyle of(BuildContext context, VrxTypeRole role) {
    final base = switch (role) {
      VrxTypeRole.clock => Theme.of(context).textTheme.displayLarge,
      VrxTypeRole.display => Theme.of(context).textTheme.displaySmall,
      VrxTypeRole.title ||
      VrxTypeRole.iconLarge =>
        Theme.of(context).textTheme.titleLarge,
      VrxTypeRole.subtitle ||
      VrxTypeRole.emphasis =>
        Theme.of(context).textTheme.titleMedium,
      VrxTypeRole.body ||
      VrxTypeRole.list ||
      VrxTypeRole.icon =>
        Theme.of(context).textTheme.bodyLarge,
      VrxTypeRole.value ||
      VrxTypeRole.subtext ||
      VrxTypeRole.caption ||
      VrxTypeRole.code =>
        Theme.of(context).textTheme.bodySmall,
      VrxTypeRole.micro => Theme.of(context).textTheme.labelSmall,
    };
    // physical points, scaled up on displays larger than the reference
    return (base ?? const TextStyle())
        .copyWith(fontSize: role.dp * VrxScale.of(context));
  }

  /// Convenience: the one large thing on a screen.
  static TextStyle display(BuildContext context) =>
      of(context, VrxTypeRole.display);

  /// Convenience: the clock face, digits only.
  static TextStyle clock(BuildContext context) =>
      of(context, VrxTypeRole.clock);

  /// Convenience: the screen's own name.
  static TextStyle title(BuildContext context) =>
      of(context, VrxTypeRole.title);

  /// Convenience: a section within a screen.
  static TextStyle subtitle(BuildContext context) =>
      of(context, VrxTypeRole.subtitle);

  /// Convenience: the part of a sentence that carries it.
  static TextStyle emphasis(BuildContext context) =>
      of(context, VrxTypeRole.emphasis);

  /// Convenience: the default.
  static TextStyle body(BuildContext context) =>
      of(context, VrxTypeRole.body);

  /// Convenience: a row's primary label.
  static TextStyle list(BuildContext context) =>
      of(context, VrxTypeRole.list);

  /// Convenience: the reading on the right of a row.
  static TextStyle value(BuildContext context) =>
      of(context, VrxTypeRole.value);

  /// Convenience: an explanation under a control.
  static TextStyle subtext(BuildContext context) =>
      of(context, VrxTypeRole.subtext);

  /// Convenience: a unit, timestamp, footnote.
  static TextStyle caption(BuildContext context) =>
      of(context, VrxTypeRole.caption);
}

/// The ink roles. `fill`/`onFill` are the inversion pair: pressed
/// fills invert; an ON chip is filled with a knocked-out glyph.
class VrxPalette {
  const VrxPalette({
    required this.text,
    required this.secondary,
    required this.faint,
    required this.page,
    required this.fill,
    required this.onFill,
    required this.line,
    required this.focus,
    required this.highlight,
  });

  /// The e-paper lineage: a light page, dark ink, inversion fills.
  factory VrxPalette.paper() => const VrxPalette(
        text: Color(0xFF202020),
        secondary: Color(0xFF606060),
        faint: Color(0xFFA0A0A0), // decoration only, never text
        page: Color(0xFFFFFFFF),
        fill: Color(0xFF000000),
        onFill: Color(0xFFFFFFFF),
        line: Color(0xFF000000),
        focus: Color(0xFF000000),
        highlight: Color(0xFFFFFFFF),
      );

  /// The scanned-panel dark palette; `fill` is the product accent and
  /// `onFill` is whichever of black/white contrasts better (4.58:1
  /// floor).
  factory VrxPalette.dark({required Color accent}) => VrxPalette(
        text: const Color(0xFFEDEDED),
        secondary: const Color(0xFFB0B0B0),
        faint: const Color(0xFF6E6E6E),
        page: const Color(0xFF121212),
        fill: accent,
        onFill: accent.computeLuminance() > 0.5
            ? Colors.black
            : Colors.white,
        // a divider is structure, not ink: quiet on a lit panel
        line: const Color(0xFF2E2E30),
        focus: const Color(0xFFEDEDED),
        highlight: Colors.white.withValues(alpha: 0.05),
      );

  final Color text;
  final Color secondary;
  final Color faint;
  final Color page;
  final Color fill;
  final Color onFill;
  final Color line;
  final Color focus;
  final Color highlight;
}

/// The product accent on colour panels.
const Color vrxAccent = Color(0xFF4C8DFF);

/// The palette for a display: `paper` for e-paper, the dark palette
/// with the product accent for colour panels.
VrxPalette paletteFor({required bool colour}) =>
    colour ? VrxPalette.dark(accent: vrxAccent) : VrxPalette.paper();

/// Material's theme, derived from a vrx palette, so stock widgets
/// (scaffolds, ink, icons, dividers) speak the same colours as vrx's.
/// Roboto is the UI face (the image ships it, ttf-roboto); the clock
/// role uses its tabular digits.
ThemeData vrxThemeData(VrxPalette palette) {
  final dark = palette.page.computeLuminance() < 0.5;
  final scheme = ColorScheme(
    brightness: dark ? Brightness.dark : Brightness.light,
    primary: palette.fill,
    onPrimary: palette.onFill,
    secondary: palette.fill,
    onSecondary: palette.onFill,
    error: const Color(0xFFFF5A5F),
    onError: Colors.white,
    surface: palette.page,
    onSurface: palette.text,
  );
  final base = ThemeData(
    colorScheme: scheme,
    fontFamily: 'Roboto',
    scaffoldBackgroundColor: palette.page,
    dividerColor: palette.line,
    // Material Symbols' axes: outlined, regular weight; a selected or
    // primary glyph passes fill: 1
    iconTheme: IconThemeData(color: palette.text, fill: 0, weight: 400, grade: 0),
    splashColor: palette.fill.withValues(alpha: 0.24),
    highlightColor: palette.highlight,
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(bodyColor: palette.text, displayColor: palette.text),
  );
}

/// [InheritedWidget] installing the active palette (the host resolves
/// it at boot; applets read, never choose).
class VrxTheme extends InheritedWidget {
  const VrxTheme({
    super.key,
    required this.palette,
    required super.child,
  });

  final VrxPalette palette;

  static VrxPalette of(BuildContext context) {
    final theme =
        context.dependOnInheritedWidgetOfExactType<VrxTheme>();
    return theme?.palette ?? VrxPalette.paper();
  }

  @override
  bool updateShouldNotify(VrxTheme oldWidget) =>
      oldWidget.palette != palette;
}
