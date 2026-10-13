/// Motion presets: the applet never hand-tunes a curve. Push slides
/// in from the right; a modal fades over a dimmed field; these are
/// the vrx verbs, matched system-wide so every applet moves alike.
library;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import 'theme.dart';
import 'ui_standard.g.dart';

/// The motion tokens: six springs, androidx Material 3 values, ported
/// to Flutter's spring physics (mass 1). Spatial tokens may overshoot
/// (position/size/rotation); effects tokens are critically damped
/// (colour/opacity) — a colour refuses a spatial spring.
abstract final class MotionTokens {
  // the standard's [springs.standard]; the generator gives Flutter the
  // damping coefficient (ratio x 2 sqrt(k m)), androidx's same physics
  static const SpringDescription spatialFast = SpringDescription(
      mass: vrxSpringMass, stiffness: vrxSpringSpatialFastStiffness, damping: vrxSpringSpatialFastDamping);
  static const SpringDescription spatial =
      SpringDescription(mass: vrxSpringMass, stiffness: vrxSpringSpatialStiffness, damping: vrxSpringSpatialDamping);
  static const SpringDescription spatialSlow = SpringDescription(
      mass: vrxSpringMass, stiffness: vrxSpringSpatialSlowStiffness, damping: vrxSpringSpatialSlowDamping);
  static const SpringDescription effectsFast = SpringDescription(
      mass: vrxSpringMass, stiffness: vrxSpringEffectsFastStiffness, damping: vrxSpringEffectsFastDamping);
  static const SpringDescription effects =
      SpringDescription(mass: vrxSpringMass, stiffness: vrxSpringEffectsStiffness, damping: vrxSpringEffectsDamping);
  static const SpringDescription effectsSlow = SpringDescription(
      mass: vrxSpringMass, stiffness: vrxSpringEffectsSlowStiffness, damping: vrxSpringEffectsSlowDamping);

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
