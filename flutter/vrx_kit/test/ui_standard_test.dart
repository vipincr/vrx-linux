import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/src/ui_standard.g.dart';

/// WCAG 2's contrast ratio times 100, as evrx-rt's ui_contrast_x100.
int contrastX100(int a, int b) {
  double lum(int argb) {
    double c(int v) {
      final s = v / 255.0;
      return s <= 0.04045 ? s / 12.92 : math.pow((s + 0.055) / 1.055, 2.4).toDouble();
    }

    return 0.2126 * c((argb >> 16) & 0xFF) + 0.7152 * c((argb >> 8) & 0xFF) + 0.0722 * c(argb & 0xFF);
  }

  final la = lum(a), lb = lum(b);
  final hi = math.max(la, lb), lo = math.min(la, lb);
  return ((hi + 0.05) / (lo + 0.05) * 100).floor();
}

/// The tables vrx_kit draws with hold the floors the standard was generated to hold, in every scheme and
/// polarity and on the grey panels, and the shape the kit relies on.
void main() {
  test('32 slots, 20 schemes numbered 1 to 20, every row complete', () {
    expect(VrxSlot.values, hasLength(32));
    expect(vrxSchemes.map((s) => s.id), List.generate(20, (i) => i + 1));
    for (final s in vrxSchemes) {
      expect((s.light.length, s.dark.length), (32, 32), reason: 'scheme ${s.id}');
    }
    expect((vrxMapGrey4.length, vrxMapGrey2.length), (32, 32));
  });

  test('every pair holds its floor in every scheme and polarity', () {
    final misses = <String>[];
    for (final s in vrxSchemes) {
      for (final (name, table) in [('light', s.light), ('dark', s.dark)]) {
        for (final p in vrxPairFloors) {
          final got = contrastX100(table[p.bg.index], table[p.fg.index]);
          // the standard's generator rounds through its own colour maths; one hundredth of slack
          if (got + 1 < p.minX100) misses.add('scheme ${s.id} $name ${p.fg.name} on ${p.bg.name}: $got < ${p.minX100}');
        }
      }
    }
    expect(misses, isEmpty);
  });

  test('on a four-grey panel every text pair is legible, and the old paper values are kept', () {
    int grey(int level) => 0xFF000000 | level << 16 | level << 8 | level;
    for (final p in vrxPairFloors.where((p) => p.minX100 >= 450)) {
      final got = contrastX100(grey(vrxMapGrey4[p.bg.index]), grey(vrxMapGrey4[p.fg.index]));
      expect(got, greaterThanOrEqualTo(p.minX100), reason: '${p.fg.name} on ${p.bg.name}');
    }
    // evrx-rt's [pin_grey4]: the e-paper glass does not change
    expect(vrxMapGrey4[VrxSlot.text.index], 0x20);
    expect(vrxMapGrey4[VrxSlot.textSecondary.index], 0x60);
    expect(vrxMapGrey4[VrxSlot.page.index], 0xFF);
    expect(vrxMapGrey4[VrxSlot.primary.index], 0x00);
  });

  test('the on-colour of a fill is the next slot', () {
    for (final s in VrxSlot.values) {
      if ((vrxSlotHasOnMask >> s.index) & 1 == 1) {
        expect(VrxSlot.values[s.index + 1].name.toLowerCase(), 'on${s.name}'.toLowerCase());
      }
    }
    expect(vrxClassNames['lcd_colour'], VrxDisplayClass.lcdColour);
    expect(vrxClasses[VrxDisplayClass.lcdColour]!.pressedLayerPermille, 200);
    expect(vrxClasses[VrxDisplayClass.epaperGrey]!.pressedLayerPermille, 0);
  });
}
