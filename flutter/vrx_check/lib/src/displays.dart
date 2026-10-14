/// The displays vrx boards drive, as the runtime sees them: pixels, and
/// the pixel ratio flutter-vrx derives from the panel's millimetres
/// (1 logical px = 1/6.299 mm, the density vrx_kit's metrics are in).
library;

import 'dart:convert';
import 'dart:io';

class Display {
  const Display(this.name, this.width, this.height, this.widthMm, {this.touch = true, this.turns = false});

  final String name;

  /// Pixels.
  final double width, height;

  /// The panel's width in mm (the connector's); 0 when it reports none,
  /// and flutter-vrx then keeps the pixel ratio at 1.0.
  final double widthMm;

  /// Fingers on it (the 9mm minimum is a promise there).
  final bool touch;

  /// vrx may show it turned a quarter (displays.json): a panel fixed in
  /// its carrier, on a controller that cannot scan out 90 degrees, never
  /// is, and its turned shape is not checked.
  final bool turns;

  double get pixelRatio => widthMm <= 0 ? 1.0 : width / widthMm / (160 / 25.4);

  /// The same panel turned a quarter (plan 0013 D10): its pixels swapped,
  /// at the same density. An applet whose manifest says
  /// `orientation = "any"` is laid out at this shape too.
  Display get turned => Display('$name turned', height, width, widthMm <= 0 ? 0 : widthMm * height / width, touch: touch, turns: turns);

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
  final panels = [
    for (final d in (table['displays'] as List).cast<Map<String, dynamic>>())
      Display(
        '${d['name']}',
        (d['width'] as num).toDouble(),
        (d['height'] as num).toDouble(),
        (d['width_mm'] as num).toDouble(),
        touch: d['touch'] as bool,
        turns: d['turns'] as bool? ?? false,
      ),
  ];
  // the applet under test (its tests run in its own directory) says
  // whether it turns with the device: then every display's turned shape
  // is a display too (plan 0013 D10)
  return [
    ...panels,
    if (_turns()) ...panels.where((d) => d.turns).map((d) => d.turned),
  ];
}();

/// The current package's manifest declares `orientation = "any"`.
bool _turns() {
  // vrx-allow: test-time setup
  final manifest = File('manifest.toml');
  if (!manifest.existsSync()) return false;
  // vrx-allow: test-time setup
  return RegExp(r'^\s*orientation\s*=\s*"any"', multiLine: true).hasMatch(manifest.readAsStringSync());
}

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
