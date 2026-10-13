/// Display scaling: elements scale correctly with respect to the
/// display size — an onboard 480-wide panel and a 1080p HDMI screen
/// both show a correctly proportioned UI.
///
/// The model: the design's reference UI space (the evrx-rt lineage:
/// 480 logical px on the short side) defines scale 1.0, where the
/// mm-derived constants in metrics.dart are exact. A display's scale
/// is its short side over the reference, clamped so a pathological
/// display cannot make elements vanish or explode. Physical sizing
/// comes from the runtime's pixel ratio: the compositor (part E)
/// reports each panel's true density, HDMI from its EDID, onboard
/// panels from the device tree — the rendering contract's twin.
library;

import 'package:flutter/widgets.dart';

import 'metrics.dart';

/// The reference short side: 480 logical px (the evrx-rt UI space).
const double referenceShortSide = 480;

/// The scale bounds. Never below 1.0: the metrics are physical (a 9mm
/// touch minimum, 3.5mm body text, given a pixel ratio from the panel's
/// real size), so a display smaller than the reference keeps them and
/// fits fewer elements rather than shrinking them under a finger
/// (bench 2026-10-13: the 2.8" disp28a at 0.75 was unreadable). Above
/// 3.0 a display has left the design's proportions behind.
const double minScale = 1.0;
const double maxScale = 3.0;

/// The display's scale factor.
class VrxScale extends InheritedWidget {
  VrxScale({super.key, required MediaQueryData media, required super.child})
      : scale = _of(media);

  /// The resolved scale: display short side over the reference.
  final double scale;

  static double _of(MediaQueryData media) {
    final short = media.size.shortestSide;
    final raw = short / referenceShortSide;
    return raw.clamp(minScale, maxScale);
  }

  /// The scale for the display the applet is on.
  static double of(BuildContext context) {
    final scale =
        context.dependOnInheritedWidgetOfExactType<VrxScale>();
    return scale?.scale ?? 1.0;
  }

  /// Install at the app root (the runtime's host does this once).
  static Widget install({required Widget child}) {
    return Builder(
      builder: (context) =>
          VrxScale(media: MediaQuery.of(context), child: child),
    );
  }

  @override
  bool updateShouldNotify(VrxScale oldWidget) =>
      oldWidget.scale != scale;
}

/// The spacing scale, multiplied by the display's scale: exact mm at
/// the reference UI space, proportional on any other display. The
/// base numbers stay in metrics.dart — one source of truth; this is
/// the context-scoped multiplier over them.
class ScaledSpacing {
  ScaledSpacing._(this._s);

  final double _s;

  /// The scaled spacing for the display the applet is on.
  static ScaledSpacing of(BuildContext context) =>
      ScaledSpacing._(VrxScale.of(context));

  double get xs => Spacing.xs * _s;
  double get sm => Spacing.sm * _s;
  double get md => Spacing.md * _s;
  double get lg => Spacing.lg * _s;
  double get xl => Spacing.xl * _s;
  double get touch => Spacing.touch * _s;
  double get inset => Spacing.inset * _s;
  double get gutter => Spacing.gutter * _s;

  /// The minimum height of an interactive element, by modality: the
  /// 9mm touch minimum on a touch display; content height on a
  /// non-touch one (dense dashboards are sanctioned there).
  static double minInteractive(BuildContext context) =>
      VrxInput.of(context) == VrxInputModality.touch
          ? Spacing.touch * VrxScale.of(context)
          : 0;
}

/// The input modality: whether the display is touched. A touch
/// display floors every interactive element at the 9mm minimum; a
/// non-touch display (a dashboard panel, a monitor viewed at
/// distance, a headless output) is free of that floor — rows size to
/// content, gauges/tables/charts pack densely. The runtime installs
/// the modality from the hardware (the compositor knows whether the
/// panel has a touch input — part E); the default is touch, because
/// assuming density on a touch screen puts a finger on nothing.
enum VrxInputModality {
  /// Fingers drive it: the 9mm minimum floors interactive sizes.
  touch,

  /// Eyes drive it: no touch floor; dense layouts (dashboards,
  /// gauges, tables, charts) are sanctioned. Navigation, when needed,
  /// arrives by keys/focus, never by hit targets.
  view,
}

/// [InheritedWidget] installing the modality (the runtime's host).
class VrxInput extends InheritedWidget {
  const VrxInput({
    super.key,
    required this.modality,
    required super.child,
  });

  final VrxInputModality modality;

  static VrxInputModality of(BuildContext context) {
    final input = context.dependOnInheritedWidgetOfExactType<VrxInput>();
    return input?.modality ?? VrxInputModality.touch;
  }

  /// Install at the app root.
  static Widget install({
    VrxInputModality modality = VrxInputModality.touch,
    required Widget child,
  }) =>
      VrxInput(modality: modality, child: child);

  @override
  bool updateShouldNotify(VrxInput oldWidget) =>
      oldWidget.modality != modality;
}
