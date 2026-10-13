import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

void main() {
  testWidgets('the keyboard types, shifts once, deletes, and finishes', (tester) async {
    final controller = TextEditingController();
    var done = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Align(alignment: Alignment.bottomCenter, child: VrxKeyboard(controller: controller, onDone: () => done = true))),
    ));
    await tester.tap(find.byIcon(VrxSymbols.arrow_upward));
    await tester.pump();
    await tester.tap(find.text('H'));
    await tester.pump();
    await tester.tap(find.text('i'));
    await tester.pump();
    expect(controller.text, 'Hi', reason: 'one shifted letter, then lower case');
    await tester.tap(find.byIcon(VrxSymbols.backspace));
    await tester.pump();
    expect(controller.text, 'H');
    await tester.tap(find.text('123'));
    await tester.pump();
    await tester.tap(find.text('7'));
    await tester.pump();
    expect(controller.text, 'H7');
    await tester.tap(find.byIcon(VrxSymbols.keyboard_return));
    expect(done, isTrue);
  });
}
