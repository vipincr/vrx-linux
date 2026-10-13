import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

/// The kit answers a press, and shows a signal, the way the display class
/// says (plan 0009 D8): a state layer on a lit panel, the inversion on a
/// grey one; a signal always with its glyph.
void main() {
  Future<void> pump(WidgetTester tester, VrxColors colors, Widget child) =>
      tester.pumpWidget(MaterialApp(theme: vrxThemeData(colors), home: Scaffold(body: Center(child: child))));

  testWidgets('a press is a primary layer on a colour panel and an inversion on e-paper', (tester) async {
    for (final (colors, layered) in [
      (VrxColors.resolve(), true),
      (VrxColors.resolve(displayClass: VrxDisplayClass.epaperGrey), false),
    ]) {
      await pump(tester, colors, VrxPress(onTap: () {}, child: const SizedBox(width: 80, height: 60, child: Text('Go'))));
      final gesture = await tester.startGesture(tester.getCenter(find.text('Go')));
      await tester.pump(const Duration(milliseconds: 150));
      final layer = find.byWidgetPredicate((w) =>
          w is DecoratedBox &&
          w.position == DecorationPosition.foreground &&
          (w.decoration as BoxDecoration).color == colors.primary.withValues(alpha: 0.2));
      final inverted = find.byWidgetPredicate((w) => w is ColoredBox && w.color == colors.primary);
      expect(layer, layered ? findsOneWidget : findsNothing, reason: '${colors.displayClass}');
      expect(inverted, layered ? findsNothing : findsOneWidget, reason: '${colors.displayClass}');
      await gesture.up();
      await tester.pumpAndSettle();
    }
  });

  testWidgets('a banner is its signal: the slot, the on-colour and the glyph', (tester) async {
    final colors = VrxColors.resolve();
    await pump(tester, colors, const VrxBanner(text: 'Saved', signal: VrxSignal.success));
    expect(find.byIcon(VrxSymbols.check_circle), findsOneWidget);
    final band = tester.widget<Container>(find.ancestor(of: find.text('Saved'), matching: find.byType(Container)).first);
    expect(band.color, colors.success);
    expect(tester.widget<Text>(find.text('Saved')).style!.color, colors.onSuccess);
  });
}
