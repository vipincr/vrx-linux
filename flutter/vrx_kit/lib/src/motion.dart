/// Motion presets: the applet never hand-tunes a curve. Push slides
/// in from the right; a modal fades over a dimmed field; these are
/// the vrx verbs, matched system-wide so every applet moves alike.
library;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import 'theme.dart';

/// The motion tokens: six springs, androidx Material 3 values, ported
/// to Flutter's spring physics (mass 1). Spatial tokens may overshoot
/// (position/size/rotation); effects tokens are critically damped
/// (colour/opacity) — a colour refuses a spatial spring.
abstract final class MotionTokens {
  // c = ratio * 2 * sqrt(k * m), m = 1 (Flutter takes the damping
  // coefficient; androidx takes the ratio — same physics, exact port)
  static const SpringDescription spatialFast =
      SpringDescription(mass: 1, stiffness: 1400, damping: 67.34983);
  // ^ ratio 0.9 (may overshoot: position/size/rotation)
  static const SpringDescription spatial =
      SpringDescription(mass: 1, stiffness: 700, damping: 47.62352);
  // ^ ratio 0.9 (may overshoot: position/size/rotation)
  static const SpringDescription spatialSlow =
      SpringDescription(mass: 1, stiffness: 300, damping: 31.17691);
  // ^ ratio 0.9 (may overshoot: position/size/rotation)
  static const SpringDescription effectsFast =
      SpringDescription(mass: 1, stiffness: 3800, damping: 123.28828);
  // ^ ratio 1.0 (critically damped: colour/opacity)
  static const SpringDescription effects =
      SpringDescription(mass: 1, stiffness: 1600, damping: 80.00000);
  // ^ ratio 1.0 (critically damped: colour/opacity)
  static const SpringDescription effectsSlow =
      SpringDescription(mass: 1, stiffness: 800, damping: 56.56854);
  // ^ ratio 1.0 (critically damped: colour/opacity)

  /// A spring simulation for a token, from `from` to `to`.
  static SpringSimulation simulate(
    SpringDescription spring,
    double from,
    double to,
  ) =>
      SpringSimulation(spring, from, to, 0);
}

/// The vrx motion presets.
abstract final class Motion {
  /// Slide the screen in from the right (a push).
  static PageRouteBuilder<T> push<T>(Widget screen) {
    return PageRouteBuilder<T>(
      pageBuilder: (context, animation, secondary) => screen,
      transitionsBuilder: (context, animation, secondary, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
        );
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(1, 0),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        );
      },
    );
  }

  /// Fade in over a dimmed background (a modal).
  static PageRouteBuilder<T> modal<T>(BuildContext context, Widget screen) {
    return PageRouteBuilder<T>(
      opaque: false,
      // the page dimmed, as the drawer's scrim: the field behind stays legible
      barrierColor: VrxTheme.of(context).page.withValues(alpha: 0.6),
      pageBuilder: (context, animation, secondary) => screen,
      transitionsBuilder: (context, animation, secondary, child) {
        return FadeTransition(
          opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
          child: child,
        );
      },
    );
  }
}
