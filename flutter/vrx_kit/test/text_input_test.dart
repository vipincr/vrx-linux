import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_check/vrx_check.dart';
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
      home: Scaffold(body: VrxInputRoot(child: VrxKeyboardSlot(settings: s, child: Center(child: field)))),
    ));
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });
  // autofocus lands after the first frame, and the field attaches then
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('a focused field brings its keyboard up; it types, shifts once, deletes and submits', (tester) async {
    final controller = TextEditingController();
    String? submitted;
    await _host(
      tester,
      await tester.runAsync(() => _settings(facts: 'touch=1\nkeyboard=0\n')) as ScreenSettings,
      VrxTextField(controller: controller, autofocus: true, onSubmitted: (t) => submitted = t),
    );
    expect(find.byType(VrxKeyboard), findsOneWidget, reason: 'focus brings the field its keyboard');
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
    expect(submitted, 'H7', reason: "Enter is the field's submit");
  }, variant: onDevice);

  testWidgets('Enter in a multi-line field types a newline', (tester) async {
    final controller = TextEditingController(text: 'a');
    await _host(
      tester,
      await tester.runAsync(() => _settings()) as ScreenSettings,
      SizedBox(height: 100, child: VrxTextField(controller: controller, autofocus: true, maxLines: null)),
    );
    await tester.tap(find.byIcon(VrxSymbols.keyboard_return));
    await tester.pump();
    expect(controller.text, 'a\n');
  }, variant: onDevice);

  testWidgets('a plugged-in keyboard keeps it away unless Settings says show', (tester) async {
    await _host(
      tester,
      await tester.runAsync(() => _settings(facts: 'touch=1\nkeyboard=1\n')) as ScreenSettings,
      VrxTextField(controller: TextEditingController(), autofocus: true),
    );
    await _until(tester, () => find.byType(VrxKeyboard).evaluate().isEmpty);
    expect(find.byType(VrxKeyboard), findsNothing, reason: 'Only without a keyboard is the default');
    await _host(
      tester,
      await tester.runAsync(() => _settings(facts: 'touch=1\nkeyboard=1\n', conf: 'on_screen_keyboard=show\n'))
          as ScreenSettings,
      VrxTextField(controller: TextEditingController(), autofocus: true),
    );
    await _until(tester, () => find.byType(VrxKeyboard).evaluate().isNotEmpty);
    expect(find.byType(VrxKeyboard), findsOneWidget, reason: 'Show brings it up anyway');
  }, variant: onDevice);

  testWidgets('plugging a keyboard in puts it away, unplugging brings it back', (tester) async {
    final dir = await tester.runAsync(() => Directory.systemTemp.createTemp('vrx-input')) as Directory;
    final facts = File('${dir.path}/screen');
    await tester.runAsync(() async {
      await File('${dir.path}/screen.conf').writeAsString('');
      await facts.writeAsString('touch=1\nkeyboard=0\n');
    });
    final s = ScreenSettings(dir: dir.path, capsPath: facts.path, backlights: '${dir.path}/none');
    await _host(tester, s, VrxTextField(controller: TextEditingController(), autofocus: true));
    expect(find.byType(VrxKeyboard), findsOneWidget);
    await tester.runAsync(() => facts.writeAsString('touch=1\nkeyboard=1\n'));
    await _until(tester, () => find.byType(VrxKeyboard).evaluate().isEmpty);
    expect(find.byType(VrxKeyboard), findsNothing, reason: 'plugged in');
    await tester.runAsync(() => facts.writeAsString('touch=1\nkeyboard=0\n'));
    await _until(tester, () => find.byType(VrxKeyboard).evaluate().isNotEmpty);
    expect(find.byType(VrxKeyboard), findsOneWidget, reason: 'unplugged, the focused field takes it back');
  }, variant: onDevice);

  testWidgets('a key press does not decide it: only what is plugged in does', (tester) async {
    await _host(tester, await tester.runAsync(() => _settings()) as ScreenSettings,
        VrxTextField(controller: TextEditingController(), autofocus: true));
    expect(find.byType(VrxKeyboard), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.pump();
    expect(find.byType(VrxKeyboard), findsOneWidget, reason: 'the decision is what is plugged in, never the last key');
  }, variant: onDevice);

  testWidgets('a field that brings its own keys gets none', (tester) async {
    await _host(
      tester,
      await tester.runAsync(() => _settings()) as ScreenSettings,
      VrxTextField(controller: TextEditingController(), autofocus: true, kind: VrxInputKind.none),
    );
    expect(find.byType(VrxKeyboard), findsNothing);
  }, variant: onDevice);

  testWidgets('the keyboard is the focused field\'s: it follows focus and leaves with it', (tester) async {
    final a = TextEditingController(), b = TextEditingController();
    final fb = FocusNode();
    await _host(
      tester,
      await tester.runAsync(() => _settings()) as ScreenSettings,
      Column(mainAxisSize: MainAxisSize.min, children: [
        VrxTextField(controller: a, autofocus: true),
        VrxTextField(controller: b, focusNode: fb),
        // a bare Flutter field: the root attaches nothing for it
        const TextField(key: Key('bare')),
      ]),
    );
    await tester.tap(find.text('q'));
    await tester.pump();
    fb.requestFocus();
    await tester.pump();
    await tester.pump();
    await tester.tap(find.text('w'));
    await tester.pump();
    expect((a.text, b.text), ('q', 'w'), reason: 'each field types into itself');
    await tester.tap(find.byKey(const Key('bare')));
    await tester.pump();
    await tester.pump();
    expect(find.byType(VrxKeyboard), findsNothing, reason: 'focus left the kit fields, and their keyboard with it');
  }, variant: onDevice);

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
  }, variant: onDevice);
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
