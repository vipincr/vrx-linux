/// Screenshots: the same mount as the layout check, written to a PNG for
/// a person who wants to see a screen.
///
/// `flutter test --update-goldens test/shots_test.dart` writes
/// test/shots/DISPLAY-NAME.png. Shots are not a gate: the layout check
/// is (layout.dart).
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

import 'src/displays.dart';
import 'src/fonts.dart';

/// Mount [applet] as runApplet would on [display], let [setUp] act on
/// it, and write test/shots/DISPLAY-NAME.png.
Future<void> shotApplet<S, A, V>(
  WidgetTester tester,
  String name,
  Applet<S, A, V> applet, {
  Display display = disp28a,
  Future<void> Function(WidgetTester tester)? setUp,
}) async {
  await loadVrxFonts();
  tester.view.physicalSize = Size(display.width, display.height);
  tester.view.devicePixelRatio = display.pixelRatio;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(AppletHost<S, A, V>(applet: applet));
  await tester.pump(const Duration(milliseconds: 50));
  if (setUp != null) await setUp(tester);
  await tester.pump(const Duration(seconds: 1));
  await expectLater(find.byType(AppletHost<S, A, V>), matchesGoldenFile('shots/${display.name}-$name.png'));
}
