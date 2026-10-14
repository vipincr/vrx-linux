/// The one periodic source an applet may use (plan 0011 D3, G021).
///
/// Foreground is Flutter's own lifecycle: flutter-vrx sends
/// `AppLifecycleState.hidden` when the applet loses focus or the screen
/// goes off, and `resumed` when it is in front again (plan 0010 D4,
/// plan 0011 D3). A tick costs power and a frame, so a [VrxTicker] rests
/// while the applet is hidden and ticks once at once when it is back, so
/// what it drives is current the moment it shows.
///
/// [VrxTicker.background] keeps ticking behind other applets and with
/// the screen off. It is for work that must happen whether or not anyone
/// is looking (Clock's ring giving up after its 30 s), and the call site
/// says so.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

class VrxTicker {
  /// Ticks every [period] while the applet is in front.
  VrxTicker(this.period, this.onTick) : background = false {
    _lifecycle = AppLifecycleListener(onStateChange: _follow);
    // started while hidden (a warm tile): rest until shown
    final state = WidgetsBinding.instance.lifecycleState;
    if (state != AppLifecycleState.hidden && state != AppLifecycleState.paused) _start();
  }

  /// Ticks every [period] whether or not the applet is in front.
  VrxTicker.background(this.period, this.onTick) : background = true {
    _start();
  }

  final Duration period;
  final void Function() onTick;

  /// Ticks while hidden too.
  final bool background;

  Timer? _timer;
  AppLifecycleListener? _lifecycle;
  bool _cancelled = false;

  /// Ticking now (false while resting or after [cancel]).
  bool get active => _timer?.isActive ?? false;

  void _start() {
    if (_cancelled) return;
    _timer?.cancel();
    _timer = Timer.periodic(period, (_) => onTick()); // poll-ok: VrxTicker, the one periodic source, rests while the applet is hidden (G021)
  }

  // by the state itself, not the transition callbacks: a state may arrive
  // without the ones between (resumed straight to hidden)
  void _follow(AppLifecycleState state) {
    final shown = state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;
    if (!shown) {
      _timer?.cancel();
    } else if (!active && !_cancelled) {
      // back in front: what the tick drives is brought up to date at once
      onTick();
      _start();
    }
  }

  /// Stop for good.
  void cancel() {
    _cancelled = true;
    _timer?.cancel();
    _lifecycle?.dispose();
    _lifecycle = null;
  }
}
