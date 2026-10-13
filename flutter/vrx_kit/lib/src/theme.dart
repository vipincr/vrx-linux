/// The vrx design system's type and colour, from the vrx UI standard
/// (standard/vrx-ui-standard.toml, generated into ui_standard.g.dart).
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
import 'symbols.dart';
import 'ui_standard.g.dart';

/// The type scale. CLOCK renders digits only (`0-9:-`, no fallback
/// face); CODE is monospace; MICRO is subscripts only.
enum VrxTypeRole {
  clock(vrxTypePtClock),
  display(vrxTypePtDisplay),
  title(vrxTypePtTitle),
  iconLarge(vrxTypePtTitle),
  subtitle(vrxTypePtSubtitle),
  emphasis(vrxTypePtSubtitle),
  body(vrxTypePtBody),
  list(vrxTypePtBody),
  icon(vrxTypePtBody),
  value(vrxTypePtSubtext),
  subtext(vrxTypePtSubtext),
  caption(vrxTypePtSubtext),
  code(vrxTypePtCode),
  micro(vrxTypePtMicro);

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

/// The colours this device draws with: the 32 slots of the vrx UI standard
/// (plan 0009 D2), resolved once at boot from the display class, the
/// scheme and the polarity. A widget names what a colour is for
/// (`colors.text`, `colors.primary`), never a colour.
@immutable
class VrxColors extends ThemeExtension<VrxColors> with VrxSlotNames {
  const VrxColors._(this._table, this.displayClass, this.dark, this.scheme);

  /// The table for a display: a colour panel draws [scheme] (1 to 20) in
  /// the light or dark polarity; a grey panel draws its class's grey map,
  /// every slot a grey with r = g = b (evrx-rt's `ui_color_table`).
  factory VrxColors.resolve({
    VrxDisplayClass displayClass = VrxDisplayClass.lcdColour,
    int scheme = vrxDefaultScheme,
    bool dark = true,
  }) {
    if (displayClass == VrxDisplayClass.lcdColour) {
      final id = scheme >= 1 && scheme <= vrxSchemes.length ? scheme : vrxDefaultScheme;
      final row = vrxSchemes[id - 1];
      return VrxColors._(List.unmodifiable((dark ? row.dark : row.light).map(Color.new)), displayClass, dark, id);
    }
    final map = displayClass == VrxDisplayClass.epaperMono ? vrxMapGrey2 : vrxMapGrey4;
    return VrxColors._(
      List.unmodifiable(map.map((g) => Color(0xFF000000 | g << 16 | g << 8 | g))),
      displayClass,
      false,
      0,
    );
  }

  /// A scheme as a colour panel would draw it (a swatch in Settings).
  factory VrxColors.preview(int scheme, {required bool dark}) =>
      VrxColors.resolve(scheme: scheme, dark: dark);

  /// How many schemes there are to choose from.
  static int get schemeCount => vrxSchemes.length;

  /// A scheme's name: its seed and its harmony rule ("Amber complementary").
  static String schemeName(int scheme) {
    if (scheme < 1 || scheme > vrxSchemes.length) return '';
    final row = vrxSchemes[scheme - 1];
    const rules = {
      'analogous': 'analogous',
      'complementary': 'complementary',
      'split': 'split complementary',
      'triadic': 'triadic',
      'tetradic': 'tetradic',
    };
    final seed = row.seed[0].toUpperCase() + row.seed.substring(1);
    return '$seed ${rules[row.rule] ?? row.rule}';
  }

  final List<Color> _table;
  final VrxDisplayClass displayClass;

  /// The dark polarity (only ever true on a colour panel).
  final bool dark;

  /// The scheme drawn (1 to 20); 0 on a grey panel, which has none.
  final int scheme;

  /// This panel draws a scheme a person may choose (a colour panel).
  bool get schemeChoosable => scheme > 0;

  @override
  Color operator [](VrxSlot slot) => _table[slot.index];

  /// The colour drawn on [slot]: its own on-colour where it has one (a
  /// fill, a container, the inverse, a signal), the text colour on a
  /// surface (evrx-rt's `ui_style_tonal`).
  Color on(VrxSlot slot) =>
      (vrxSlotHasOnMask >> slot.index) & 1 == 1 ? _table[slot.index + 1] : text;

  /// What differs by kind of panel: the press, the pacing.
  VrxClassRow get classRow => vrxClasses[displayClass]!;

  @override
  VrxColors copyWith() => this;

  /// No tween between schemes: the scheme changes at boot (plan 0009 D5).
  @override
  VrxColors lerp(VrxColors? other, double t) => t < 0.5 || other == null ? this : other;
}

/// A state that means something (plan 0062 D8): its slot and the glyph
/// that says it too, since a grey panel shows the slot as a grey.
enum VrxSignal {
  error(VrxSlot.error, VrxSymbols.error),
  warning(VrxSlot.warning, VrxSymbols.warning),
  success(VrxSlot.success, VrxSymbols.check_circle),
  info(VrxSlot.info, VrxSymbols.info);

  const VrxSignal(this.slot, this.glyph);
  final VrxSlot slot;
  final IconData glyph;
}

/// The scheme a device draws until its settings name another: 12, amber
/// complementary (the owner's pick for a colour board, plan 0062).
const int vrxDefaultScheme = 12;

/// The four hue names (plan 0062 D2): the signal slots by another name, so
/// red is the error colour of the active scheme and a grey on a grey panel.
/// Nothing else names a hue. A colour that means something is always shown
/// with a glyph or a word as well.
abstract final class VrxHue {
  static Color red(BuildContext context) => VrxTheme.of(context).error;
  static Color amber(BuildContext context) => VrxTheme.of(context).warning;
  static Color green(BuildContext context) => VrxTheme.of(context).success;
  static Color blue(BuildContext context) => VrxTheme.of(context).info;
}

/// Material's theme from the slots, so stock widgets (a text field, a
/// dialog, ink, icons, dividers) draw the active scheme without being told.
/// Roboto is the UI face (the image ships it, ttf-roboto); the clock role
/// uses its tabular digits.
ThemeData vrxThemeData(VrxColors c) {
  final scheme = ColorScheme(
    brightness: c.dark ? Brightness.dark : Brightness.light,
    primary: c.primary,
    onPrimary: c.onPrimary,
    primaryContainer: c.primaryContainer,
    onPrimaryContainer: c.onPrimaryContainer,
    secondary: c.secondary,
    onSecondary: c.onSecondary,
    secondaryContainer: c.secondaryContainer,
    onSecondaryContainer: c.onSecondaryContainer,
    tertiary: c.tertiary,
    onTertiary: c.onTertiary,
    tertiaryContainer: c.tertiaryContainer,
    onTertiaryContainer: c.onTertiaryContainer,
    error: c.error,
    onError: c.onError,
    surface: c.page,
    onSurface: c.text,
    onSurfaceVariant: c.textSecondary,
    surfaceContainer: c.surface,
    surfaceContainerHigh: c.surfaceHigh,
    outline: c.outline,
    outlineVariant: c.outlineFaint,
    shadow: c.shadow,
    inverseSurface: c.inverse,
    onInverseSurface: c.onInverse,
  );
  final base = ThemeData(
    colorScheme: scheme,
    extensions: [c],
    fontFamily: 'Roboto',
    scaffoldBackgroundColor: c.page,
    dividerColor: c.outlineFaint,
    // Material Symbols' axes: outlined, regular weight; a selected or
    // primary glyph passes fill: 1
    iconTheme: IconThemeData(color: c.text, fill: 0, weight: 400, grade: 0),
    splashColor: c.primary.withValues(alpha: c.classRow.pressedLayerPermille / 1000),
    highlightColor: c.surfaceHigh,
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(bodyColor: c.text, displayColor: c.text),
  );
}

/// The active colours: the [VrxColors] the applet's theme carries. The host
/// resolves them at boot; applets read, never choose.
abstract final class VrxTheme {
  static VrxColors of(BuildContext context) =>
      Theme.of(context).extension<VrxColors>() ?? VrxColors.resolve();
}
