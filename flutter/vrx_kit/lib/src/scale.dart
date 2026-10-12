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

/// The scale bounds: below 0.75 the UI would be unusably small
/// (a display that small needs its own layout), above 3.0 it has
/// left the design's proportions behind.
const double minScale = 0.75;
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
}
