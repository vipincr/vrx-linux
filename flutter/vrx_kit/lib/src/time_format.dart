/// The time format is the system's locale (plan 0011 D7). Linux keeps it
/// in LC_TIME (systemd-localed writes /etc/locale.conf); flutter-vrx reads
/// it and sends Flutter's own `alwaysUse24HourFormat` on `flutter/settings`,
/// at start and whenever the file changes. An applet never keeps a 12/24
/// setting of its own: it reads [VrxTimeFormat.use24Hour], follows
/// [VrxTimeFormat.changes], and formats with [VrxTimeFormat.hm].
library;

import 'package:flutter/foundation.dart';

abstract final class VrxTimeFormat {
  /// The system says 24-hour (Flutter's PlatformDispatcher, from the
  /// locale's LC_TIME).
  static bool get use24Hour => PlatformDispatcher.instance.alwaysUse24HourFormat;

  static ValueNotifier<bool>? _changes;

  /// [use24Hour], now and on every change of the platform's settings.
  static ValueListenable<bool> get changes {
    final existing = _changes;
    if (existing != null) return existing;
    final notifier = _changes = ValueNotifier<bool>(use24Hour);
    final dispatcher = PlatformDispatcher.instance;
    final before = dispatcher.onPlatformConfigurationChanged;
    // chained: the binding's own handler (MediaQuery) still runs
    dispatcher.onPlatformConfigurationChanged = () {
      before?.call();
      notifier.value = use24Hour;
    };
    return notifier;
  }

  /// "07:45", or "7:45 AM" in 12-hour form, from minutes after midnight.
  static String hm(int minutes, {bool? h24}) {
    final m24 = h24 ?? use24Hour;
    final h = (minutes ~/ 60) % 24, m = (minutes % 60).toString().padLeft(2, '0');
    if (m24) return '${h.toString().padLeft(2, '0')}:$m';
    return '${h % 12 == 0 ? 12 : h % 12}:$m ${h < 12 ? 'AM' : 'PM'}';
  }
}
