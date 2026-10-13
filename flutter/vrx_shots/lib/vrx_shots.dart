/// Screenshots of a vrx applet as a panel shows it.
///
/// `VRX_FONTS=DIR flutter test --update-goldens test/shots_test.dart`
/// writes test/shots/DISPLAY-NAME.png. The directory holds the image's fonts
/// (Roboto-*.ttf, MaterialSymbolsRounded.ttf, LiberationMono-Regular.ttf,
/// copied from /usr/share/fonts on a board); without VRX_FONTS the shots
/// skip, so the gate never depends on them.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

/// A display to shoot at: its pixels and its pixel ratio (the runtime
/// derives the ratio from the panel's millimetres).
class ShotDisplay {
  const ShotDisplay(this.name, this.width, this.height, this.pixelRatio);

  final String name;
  final double width, height, pixelRatio;
}

/// The bench's 2.8" disp28a: 480x640, 43x58mm.
const disp28a = ShotDisplay('disp28a', 480, 640, 1.772);

/// A 24" 1080p monitor over HDMI: 1920x1080, 527x296mm.
const hdmi1080 = ShotDisplay('hdmi1080', 1920, 1080, 0.578);

/// Null when shots are off (no VRX_FONTS), else a reason to skip.
String? get shotsSkip => Platform.environment['VRX_FONTS'] == null ? 'VRX_FONTS unset' : null;

bool _loaded = false;

/// Load the image's fonts under the families vrx_kit names.
Future<void> loadShotFonts() async {
  if (_loaded) return;
  final dir = Platform.environment['VRX_FONTS']!;
  Future<void> family(String name, List<String> files) async {
    final loader = FontLoader(name);
    for (final f in files) {
      final bytes = File('$dir/$f').readAsBytesSync();
      loader.addFont(Future.value(ByteData.sublistView(bytes)));
    }
    await loader.load();
  }

  await family('Roboto', ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Light.ttf']);
  await family('Material Symbols Rounded', ['MaterialSymbolsRounded.ttf']);
  await family('Liberation Mono', ['LiberationMono-Regular.ttf']);
  _loaded = true;
}

/// Mount [applet] as runApplet would on [display], let [setUp] act on it
/// (taps through the tester), and write test/shots/DISPLAY-NAME.png.
Future<void> shotApplet<S, A, V>(
  WidgetTester tester,
  String name,
  Applet<S, A, V> applet, {
  ShotDisplay display = disp28a,
  Future<void> Function(WidgetTester tester)? setUp,
}) async {
  await loadShotFonts();
  tester.view.physicalSize = Size(display.width, display.height);
  tester.view.devicePixelRatio = display.pixelRatio;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(AppletHost<S, A, V>(applet: applet));
  await tester.pump(const Duration(milliseconds: 50));
  if (setUp != null) await setUp(tester);
  await tester.pumpAndSettle(const Duration(milliseconds: 50), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 2));
  await expectLater(find.byType(AppletHost<S, A, V>), matchesGoldenFile('shots/${display.name}-$name.png'));
}
