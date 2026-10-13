import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

void main() {
  test('type sizes are points: body text is 3.5mm, as evrx-rt draws it', () {
    // 9.9pt at 160/72 dp per point = 22 dp = 3.49 mm at 160 dp/inch
    expect(VrxTypeRole.body.dp, closeTo(22.0, 0.05));
    expect(VrxTypeRole.body.dp / mmToDp, closeTo(3.49, 0.01));
  });

  test('a colour panel gets the accent palette, e-paper the paper one', () {
    expect(paletteFor(colour: true).fill, vrxAccent);
    expect(paletteFor(colour: false).page, VrxPalette.paper().page);
    final dark = vrxThemeData(paletteFor(colour: true));
    expect(dark.colorScheme.brightness, Brightness.dark);
    expect(dark.colorScheme.primary, vrxAccent);
  });

  test('manifest glyph names resolve; unknown ones do not', () {
    expect(VrxGlyphs.named('clock'), isNotNull);
    expect(VrxGlyphs.named('settings'), isNotNull);
    expect(VrxGlyphs.named('clock.png'), isNull);
  });
}
