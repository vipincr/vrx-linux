/// The image's fonts, so text measures here as it does on the board.
/// `cargo xtask fonts` fetches them, pinned by checksum to the sources
/// the Yocto recipes build from, into ~/.cache/vrx/fonts (or VRX_FONTS).
/// Icons need no font: an icon's box is its size, whatever the glyph.
library;

import 'dart:io';

import 'package:flutter/services.dart';

String get fontsDir =>
    Platform.environment['VRX_FONTS'] ?? '${Platform.environment['HOME'] ?? ''}/.cache/vrx/fonts';

bool _loaded = false;

/// Load Roboto (vrx_kit's face) and Liberation Mono (the terminal's).
/// Throws, naming the fix, when they have not been fetched: text
/// measured in the test font would make every width wrong.
Future<void> loadVrxFonts() async {
  if (_loaded) return;
  final dir = fontsDir;
  Future<void> family(String name, List<String> files) async {
    final loader = FontLoader(name);
    for (final f in files) {
      final file = File('$dir/$f');
      if (!file.existsSync()) {
        throw StateError('vrx_check: $dir/$f is missing; run `cargo xtask fonts`');
      }
      loader.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
    }
    await loader.load();
  }

  await family('Roboto', ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Light.ttf']);
  await family('Liberation Mono', ['LiberationMono-Regular.ttf']);
  // icons for screenshots only (an icon's box is its size either way):
  // MaterialSymbolsRounded.ttf when someone has put it there
  if (File('$dir/MaterialSymbolsRounded.ttf').existsSync()) {
    await family('Material Symbols Rounded', ['MaterialSymbolsRounded.ttf']);
  }
  _loaded = true;
}
