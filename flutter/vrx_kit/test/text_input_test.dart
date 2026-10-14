import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

/// A screen settings pair in a temporary directory: screen.conf and the
/// compositor's facts file.
Future<ScreenSettings> _settings({String facts = '', String conf = ''}) async {
  final dir = await Directory.systemTemp.createTemp('vrx-input');
  await File('${dir.path}/screen.conf').writeAsString(conf);
  await File('${dir.path}/screen').writeAsString(facts);
  return ScreenSettings(dir: dir.path, capsPath: '${dir.path}/screen', backlights: '${dir.path}/none');
}

/// Pump until [done], the files having had real time to be read (up to
/// 5 s: a loaded machine reads them late).
Future<void> _until(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 100 && !done(); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }
}

Future<void> _host(WidgetTester tester, ScreenSettings s, Widget field) async {
  // the facts and the mode are read from files: real I/O, started where
  // it can finish
  await tester.runAsync(() async {
    // a fresh state for each settings pair (a board reads them once)
    await tester.pumpWidget(MaterialApp(
      key: UniqueKey(),
      home: Scaffold(body: VrxInputRoot(child: VrxKeyboardHost(settings: s, child: Center(child: field)))),
    ));
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });
  // autofocus lands after the first frame, and the field asks then
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('a focused field brings the keyboard up; it types, shifts once, deletes and submits', (tester) async {
    final controller = TextEditingController();
    String? submitted;
    await _host(
      tester,
      await tester.runAsync(() => _settings(facts: 'touch=1\nkeyboard=0\n')) as ScreenSettings,
      TextField(controller: controller, autofocus: true, onSubmitted: (t) => submitted = t),
    );
    expect(find.byType(VrxKeyboard), findsOneWidget, reason: 'focus asks for the keyboard (plan 0013 D6)');
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
    await tester.pump();
    expect(submitted, 'H7', reason: "Enter is the field's action");
  });

  testWidgets('Enter in a multi-line field types a newline', (tester) async {
    final controller = TextEditingController(text: 'a');
    await _host(
      tester,
      await tester.runAsync(() => _settings()) as ScreenSettings,
      SizedBox(
        height: 100,
        child: TextField(controller: controller, autofocus: true, maxLines: null, keyboardType: TextInputType.multiline),
      ),
    );
    await tester.tap(find.byIcon(VrxSymbols.keyboard_return));
    await tester.pump();
    expect(controller.text, 'a\n');
  });

  testWidgets('a plugged-in keyboard puts it away unless Settings says show', (tester) async {
    await _host(
      tester,
      await tester.runAsync(() => _settings(facts: 'touch=1\nkeyboard=1\n')) as ScreenSettings,
      const TextField(autofocus: true),
    );
    await _until(tester, () => find.byType(VrxKeyboard).evaluate().isEmpty);
    expect(find.byType(VrxKeyboard), findsNothing, reason: 'Only without a keyboard is the default');
    await _host(
      tester,
      await tester.runAsync(() => _settings(facts: 'touch=1\nkeyboard=1\n', conf: 'on_screen_keyboard=show\n'))
          as ScreenSettings,
      const TextField(autofocus: true),
    );
    expect(find.byType(VrxKeyboard), findsOneWidget, reason: 'Show brings it up anyway');
  });

  testWidgets('a field that brings its own keys gets none', (tester) async {
    await _host(
      tester,
      await tester.runAsync(() => _settings()) as ScreenSettings,
      const TextField(autofocus: true, keyboardType: TextInputType.none),
    );
    expect(find.byType(VrxKeyboard), findsNothing);
  });

  testWidgets('a key from a physical keyboard puts it away', (tester) async {
    await _host(tester, await tester.runAsync(() => _settings()) as ScreenSettings, const TextField(autofocus: true));
    expect(find.byType(VrxKeyboard), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.pump();
    expect(find.byType(VrxKeyboard), findsNothing);
  });

  // G034 (plan 0013 D7): the applet root takes the touch floor from the
  // compositor's fact; without the read, a board with no touchscreen keeps
  // the 9mm floor and this fails
  testWidgets('the touch floor comes from the hardware (G034)', (tester) async {
    for (final (facts, want) in [('touch=0\n', 'view'), ('touch=1\n', 'touch')]) {
      final s = await tester.runAsync(() => _settings(facts: facts)) as ScreenSettings;
      await tester.runAsync(() async {
        await tester.pumpWidget(AppletHost(key: ValueKey(facts), applet: _Modality(), screen: s));
      });
      await _until(tester, () => find.text(want).evaluate().isNotEmpty);
      expect(find.text(want), findsOneWidget, reason: facts);
    }
  });
}

class _Modality extends Applet<int, String, int> {
  @override
  int get initial => 0;

  @override
  String get bootAction => 'init';

  @override
  int reduce(int state, String action) => state;

  @override
  int get snapshot => 0;

  @override
  Widget build(BuildContext context, int view) => Text(VrxInput.of(context).name);
}
