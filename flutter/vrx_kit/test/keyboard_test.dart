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

  testWidgets('the terminal keyboard sends keys, latches Ctrl for one, and has the shell symbols', (tester) async {
    final typed = <String>[];
    final keys = <VrxTermKey>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: VrxKeyboard.terminal(
            onText: (text, {ctrl = false}) => typed.add(ctrl ? '^$text' : text),
            onKey: keys.add,
            onHide: () {},
            onBack: () {},
          ),
        ),
      ),
    ));
    await tester.tap(find.text('ctrl'));
    await tester.pump();
    await tester.tap(find.text('c'));
    await tester.pump();
    await tester.tap(find.text('l'));
    await tester.pump();
    expect(typed, ['^c', 'l'], reason: 'Ctrl applies to one key');
    await tester.tap(find.byIcon(VrxSymbols.keyboard_arrow_up));
    await tester.tap(find.byIcon(VrxSymbols.backspace));
    await tester.tap(find.byIcon(VrxSymbols.keyboard_return));
    expect(keys, [VrxTermKey.up, VrxTermKey.backspace, VrxTermKey.enter]);
    await tester.tap(find.text('123'));
    await tester.pump();
    await tester.tap(find.text('#+='));
    await tester.pump();
    await tester.tap(find.text('|'));
    expect(typed.last, '|', reason: 'a pipe is on the second symbol page');
  });
}
