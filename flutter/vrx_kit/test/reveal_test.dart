import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

/// plan 0011 (evrx-rt docs/13 §Cut text): an ellipsis is a promise that
/// the rest can be seen. A cut value shows whole on a tap.
void main() {
  const long = 'a value long enough that two lines of a narrow row cannot hold all of it at once, whatever the panel';
  Future<void> pump(WidgetTester tester, {required bool reveals}) => tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 120,
            child: VrxRevealText(long, style: const TextStyle(fontSize: 14), reveals: reveals),
          ),
        ),
      ));

  testWidgets('a tap shows the whole text and a second cuts it again', (tester) async {
    await pump(tester, reveals: true);
    expect(tester.widget<Text>(find.text(long)).maxLines, 2);
    await tester.tap(find.text(long));
    await tester.pump();
    expect(tester.widget<Text>(find.text(long)).maxLines, isNull);
    await tester.tap(find.text(long));
    await tester.pump();
    expect(tester.widget<Text>(find.text(long)).maxLines, 2);
  });

  testWidgets('inside a control that does something it only cuts', (tester) async {
    await pump(tester, reveals: false);
    expect(find.byType(GestureDetector), findsNothing);
  });
}
