import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_check/vrx_check.dart';
import 'package:vrx_kit/vrx_kit.dart';

import 'package:shell_applet/main.dart';
import 'package:shell_applet/state.dart';

/// The shell's plane is above every applet's (plan 0008 D10): below the strip
/// it must paint nothing, or the applet in front is hidden behind it. The kit
/// filled the page under every applet, the shell too, and on 0.1.0112 no
/// applet could be seen.
void main() {
  ShellModel model() => ShellModel(now: () => DateTime(2026, 10, 15, 4, 10).millisecondsSinceEpoch)..clockValid = true;

  test('the shell is an overlay, as its manifest says (roles.shell)', () {
    final manifest = File('manifest.toml').readAsStringSync();
    final roles = RegExp(r'^\[applet\.roles\]\n((?:[^\[].*\n?)*)', multiLine: true).firstMatch(manifest)?.group(1) ?? '';
    expect(RegExp(r'^shell\s*=\s*true', multiLine: true).hasMatch(roles), isTrue, reason: 'manifest.toml [applet.roles]');
    expect(ShellApplet(model()).overlay, isTrue);
  });

  testWidgets('below the strip the shell paints nothing', (tester) async {
    await mountApplet(tester, ShellApplet(model()));
    await settleMotion(tester);
    final strip = tester.getRect(find.byType(VrxStatusStrip)).bottom;
    final view = tester.binding.renderViews.first;
    // the root layer is in physical pixels (it carries the view's scale)
    final layer = view.debugLayer! as OffsetLayer;
    final physical = tester.view.physicalSize;
    final pixels = await tester.runAsync(() async {
      final image = await layer.toImage(Offset.zero & physical);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      return (image.width, image.height, bytes!);
    });
    final (w, h, bytes) = pixels!;
    final scale = w / view.size.width;
    var painted = 0;
    for (var y = ((strip + 1) * scale).ceil(); y < h; y++) {
      for (var x = 0; x < w; x++) {
        if (bytes.getUint8((y * w + x) * 4 + 3) != 0) painted++;
      }
    }
    expect(painted, 0, reason: 'pixels with any alpha below the strip (bottom at $strip)');
  });
}
