/// Motion presets: the applet never hand-tunes a curve. Push slides
/// in from the right; a modal fades over a dimmed field; these are
/// the vrx verbs, matched system-wide so every applet moves alike.
library;

import 'package:flutter/material.dart';

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
  static PageRouteBuilder<T> modal<T>(Widget screen) {
    return PageRouteBuilder<T>(
      opaque: false,
      barrierColor: Colors.black54,
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
