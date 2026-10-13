/// The displays vrx boards drive, as the runtime sees them: pixels, and
/// the pixel ratio flutter-vrx derives from the panel's millimetres
/// (1 logical px = 1/6.299 mm, the density vrx_kit's metrics are in).
library;

import 'dart:convert';
import 'dart:io';

class Display {
  const Display(this.name, this.width, this.height, this.widthMm, {this.touch = true});

  final String name;

  /// Pixels.
  final double width, height;

  /// The panel's width in mm (the connector's); 0 when it reports none,
  /// and flutter-vrx then keeps the pixel ratio at 1.0.
  final double widthMm;

  /// Fingers on it (the 9mm minimum is a promise there).
  final bool touch;

  double get pixelRatio => widthMm <= 0 ? 1.0 : width / widthMm / (160 / 25.4);

  @override
  String toString() => name;
}

/// The table, from package:vrx_check/displays.json (the one source; the
/// Rust SDK's console check reads the same file).
final List<Display> allDisplays = () {
  // where the package lives, from the running package's own
  // .dart_tool/package_config.json (test isolates cannot resolve
  // package: URIs synchronously); read once before any test runs
  // vrx-allow: test-time setup
  final configFile = File('.dart_tool/package_config.json');
  // vrx-allow: test-time setup
  final config = jsonDecode(configFile.readAsStringSync()) as Map<String, dynamic>;
  final entry = (config['packages'] as List).cast<Map<String, dynamic>>().firstWhere((p) => p['name'] == 'vrx_check');
  final root = configFile.absolute.parent.uri.resolve('${entry['rootUri']}'.endsWith('/') ? '${entry['rootUri']}' : '${entry['rootUri']}/');
  // vrx-allow: test-time setup
  final table = jsonDecode(File.fromUri(root.resolve('lib/displays.json')).readAsStringSync()) as Map<String, dynamic>;
  return [
    for (final d in (table['displays'] as List).cast<Map<String, dynamic>>())
      Display(
        '${d['name']}',
        (d['width'] as num).toDouble(),
        (d['height'] as num).toDouble(),
        (d['width_mm'] as num).toDouble(),
        touch: d['touch'] as bool,
      ),
  ];
}();

Display _named(String name) => allDisplays.firstWhere((d) => d.name == name);

/// The bench's 2.8" panel on the CM4.
final Display disp28a = _named('disp28a');

/// The Raspberry Pi 7" touch display.
final Display dsi7 = _named('dsi7');

/// A 7" HDMI panel.
final Display hdmi7 = _named('hdmi7');

/// A 24" monitor with a mouse and keyboard.
final Display hdmi1080 = _named('hdmi1080');

/// A monitor whose EDID gives no size.
final Display hdmiNoSize = _named('hdmi-nosize');
