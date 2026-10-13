import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

void main() {
  test('type sizes are points: body text is 3.5mm, as evrx-rt draws it', () {
    // 9.9pt at 160/72 dp per point = 22 dp = 3.49 mm at 160 dp/inch
    expect(VrxTypeRole.body.dp, closeTo(22.0, 0.05));
    expect(VrxTypeRole.body.dp / mmToDp, closeTo(3.49, 0.01));
  });

  test('a colour panel draws its scheme, a grey panel its grey map, and Material follows', () {
    // scheme 12 (amber complementary), dark: the standard's values
    final colour = VrxColors.resolve();
    expect(colour.primary, const Color(0xFFFFB870));
    expect(colour.page, const Color(0xFF121212));
    expect(colour.on(VrxSlot.primary), colour.onPrimary);
    expect(colour.on(VrxSlot.surface), colour.text, reason: 'a surface has no on-colour of its own');
    final light = VrxColors.resolve(scheme: 1, dark: false);
    expect(light.primary, const Color(0xFF105EB1));
    expect(VrxColors.resolve(scheme: 99).primary, colour.primary, reason: 'an unknown scheme is the default');
    // e-paper: the paper values, whatever scheme is asked for
    final paper = VrxColors.resolve(displayClass: VrxDisplayClass.epaperGrey, scheme: 1);
    expect((paper.text, paper.page, paper.primary), (const Color(0xFF202020), const Color(0xFFFFFFFF), const Color(0xFF000000)));
    expect(paper.classRow.pressedLayerPermille, 0);
    final theme = vrxThemeData(colour);
    expect(theme.colorScheme.brightness, Brightness.dark);
    expect(theme.colorScheme.primary, colour.primary);
    expect(theme.colorScheme.tertiaryContainer, colour.tertiaryContainer);
    expect(theme.extension<VrxColors>(), same(colour));
  });

  test('the boot colours read the class and the snapshot, and fall back to the default', () {
    final dir = Directory.systemTemp.createTempSync('vrx-theme');
    final cls = File('${dir.path}/display-class')..writeAsStringSync('lcd_colour\n');
    final snap = File('${dir.path}/theme.conf')..writeAsStringSync('scheme=3\npolarity=light\n');
    var c = bootColors(classFile: cls.path, themeFile: snap.path);
    expect((c.primary, c.dark), (VrxColors.resolve(scheme: 3, dark: false).primary, false));
    snap.writeAsStringSync('scheme=abc\n');
    c = bootColors(classFile: cls.path, themeFile: snap.path);
    expect((c.primary, c.dark), (VrxColors.resolve().primary, true));
    cls.writeAsStringSync('epaper_mono');
    c = bootColors(classFile: cls.path, themeFile: '${dir.path}/absent');
    expect(c.displayClass, VrxDisplayClass.epaperMono);
    expect(c.text, const Color(0xFF000000));
    expect(bootColors(classFile: '${dir.path}/none', themeFile: '${dir.path}/none').displayClass, VrxDisplayClass.lcdColour);
    dir.deleteSync(recursive: true);
  });

  test('every Material Symbol is named; unknown names are not', () {
    expect(VrxSymbols.byName.length, greaterThan(4000));
    expect(VrxSymbols.named('schedule'), VrxSymbols.schedule);
    expect(VrxSymbols.named('10k'), VrxSymbols.$10k);
    expect(VrxSymbols.named('class'), VrxSymbols.class_);
    expect(VrxSymbols.schedule.fontFamily, 'Material Symbols Rounded');
    expect(VrxSymbols.named('clock.png'), isNull);
  });
}
