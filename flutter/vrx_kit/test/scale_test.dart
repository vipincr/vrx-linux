import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

/// Elements scale with the display: the reference short side (480)
/// shows the design's exact numbers; a 1080p HDMI short side (1080)
/// scales them 2.25×; a pathological display clamps instead of
/// vanishing or exploding.
void main() {
  Future<double> rowHeightAtShortSide(WidgetTester tester, double shortSide,
      {double longestSide = 1600}) async {
    tester.view.physicalSize = Size(shortSide, longestSide);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      VrxScale.install(
        child: const MaterialApp(
          home: Scaffold(body: VrxRow(label: 'row', value: '1')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return tester.getSize(find.byType(VrxRow)).height;
  }

  testWidgets('the reference display shows the mm-exact touch minimum',
      (tester) async {
    final h = await rowHeightAtShortSide(tester, 480, longestSide: 800);
    // 9mm at 160/25.4 dp per mm = 56.69dp; the hairline paints
    // within the row, not added to it
    expect(h, closeTo(56.69, 0.5));
  });

  testWidgets('an HDMI-sized display scales proportionally',
      (tester) async {
    final reference = await rowHeightAtShortSide(tester, 480, longestSide: 800);
    final hdmi = await rowHeightAtShortSide(tester, 1080, longestSide: 1920);
    // 1080/480 = 2.25× — the same UI, proportionally larger
    expect(hdmi / reference, closeTo(2.25, 0.05));
  });

  testWidgets('a pathological display clamps, never explodes',
      (tester) async {
    final huge = await rowHeightAtShortSide(tester, 4800);
    final reference =
        await rowHeightAtShortSide(tester, 480, longestSide: 800);
    // 10× the reference raw, clamped to 3×
    expect(huge / reference, closeTo(3.0, 0.05));
  });

  testWidgets('type scales with the display too', (tester) async {
    double fontSizeAt(double shortSide) {
      return VrxScale.of(
        tester.element(find.byType(Scaffold)),
      );
    }

    await tester.pumpWidget(
      VrxScale.install(
        child: const MaterialApp(home: Scaffold(body: SizedBox())),
      ),
    );
    tester.view.physicalSize = const Size(480, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pump();
    expect(fontSizeAt(480), closeTo(1.0, 0.01));

    tester.view.physicalSize = const Size(1080, 1920);
    await tester.pump();
    expect(fontSizeAt(1080), closeTo(2.25, 0.01));
  });
}
