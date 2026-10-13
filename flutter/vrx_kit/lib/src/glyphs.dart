/// Named glyphs: what a manifest's `display.icon` (or any applet) may
/// name, resolved to the Material icon font that every vrx applet
/// bundles (`uses-material-design: true`). A const table, so the icon
/// tree-shaker keeps exactly these.
library;

import 'package:flutter/material.dart';

abstract final class VrxGlyphs {
  /// The glyph for a name, or null for an unknown one.
  static IconData? named(String name) => _byName[name];

  /// Every name a manifest may use.
  static Iterable<String> get names => _byName.keys;

  static const Map<String, IconData> _byName = {
    'alarm': Icons.alarm_rounded,
    'apps': Icons.apps_rounded,
    'back': Icons.arrow_back_rounded,
    'battery': Icons.battery_full_rounded,
    'bluetooth': Icons.bluetooth_rounded,
    'calculator': Icons.calculate_rounded,
    'calendar': Icons.calendar_month_rounded,
    'camera': Icons.photo_camera_rounded,
    'chat': Icons.chat_rounded,
    'clock': Icons.schedule_rounded,
    'files': Icons.folder_rounded,
    'game': Icons.sports_esports_rounded,
    'heart': Icons.favorite_rounded,
    'home': Icons.home_rounded,
    'info': Icons.info_rounded,
    'language': Icons.language_rounded,
    'lock': Icons.lock_rounded,
    'mail': Icons.mail_rounded,
    'map': Icons.map_rounded,
    'music': Icons.music_note_rounded,
    'notes': Icons.sticky_note_2_rounded,
    'palette': Icons.palette_rounded,
    'person': Icons.person_rounded,
    'photo': Icons.photo_rounded,
    'power': Icons.power_settings_new_rounded,
    'search': Icons.search_rounded,
    'settings': Icons.settings_rounded,
    'star': Icons.star_rounded,
    'terminal': Icons.terminal_rounded,
    'timer': Icons.timer_rounded,
    'tune': Icons.tune_rounded,
    'weather': Icons.wb_sunny_rounded,
    'wifi': Icons.wifi_rounded,
  };
}
