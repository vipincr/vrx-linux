import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

void main() {
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
