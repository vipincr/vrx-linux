import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

Future<double> _flungTo(WidgetTester tester, double contentHeight) async {
  await tester.pumpWidget(MaterialApp(
    home: Center(
      child: SizedBox(
        height: 200,
        width: 100,
        child: VrxPaged(builder: (context, box) => SizedBox(height: contentHeight, width: 100)),
      ),
    ),
  ));
  await tester.fling(find.byType(SingleChildScrollView), const Offset(0, -60), 800);
  await tester.pumpAndSettle();
  return tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels;
}

void main() {
  // plan 0013 D9: a vertical drag nothing inside claims pages the body
  testWidgets('a body taller than the client pages, a client height at a time', (tester) async {
    expect(await _flungTo(tester, 600), 200, reason: 'one page down, snapped');
  });

  testWidgets('a body that fits does not move', (tester) async {
    expect(await _flungTo(tester, 150), 0);
  });
}
