import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_check/vrx_check.dart';
import 'package:vrx_kit/vrx_kit.dart';

/// The keyboard for each kind of value (owner, 2026-10-15): the keys each
/// kind hands, the filter both keyboards meet, one height for all, the
/// wheels' values, the gamepad's keys, and the exceptional programmatic
/// show and dismiss.

Future<ScreenSettings> _settings(WidgetTester tester, {bool keyboard = false}) async {
  final dir = await tester.runAsync(() => Directory.systemTemp.createTemp('vrx-kbd')) as Directory;
  await tester.runAsync(() async {
    await File('${dir.path}/screen.conf').writeAsString('');
    await File('${dir.path}/screen').writeAsString('touch=1\nkeyboard=${keyboard ? 1 : 0}\n');
  });
  return ScreenSettings(dir: dir.path, capsPath: '${dir.path}/screen', backlights: '${dir.path}/none');
}

/// [child] under an applet root's input watcher and keyboard place, on a
/// 480x640 panel.
Future<void> _host(WidgetTester tester, Widget child, {bool keyboard = false}) async {
  tester.view.physicalSize = const Size(480, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final s = await _settings(tester, keyboard: keyboard);
  await tester.runAsync(() async {
    await tester.pumpWidget(MaterialApp(
      key: UniqueKey(),
      home: Scaffold(body: VrxInputRoot(child: VrxKeyboardSlot(settings: s, child: child))),
    ));
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });
  await tester.pump();
  await tester.pump();
}

Future<TextEditingController> _field(WidgetTester tester, VrxInputKind kind,
    {String text = '', ValueChanged<String>? onSubmitted}) async {
  final c = TextEditingController(text: text);
  await _host(tester, Center(child: VrxTextField(controller: c, kind: kind, autofocus: true, onSubmitted: onSubmitted)));
  return c;
}

Future<void> _tapKey(WidgetTester tester, String label) async {
  await tester.tap(find.text(label).last);
  await tester.pump();
}

void main() {
  testWidgets('a tap on a key keeps the field focused and its keyboard up', (tester) async {
    final c = await _field(tester, VrxInputKind.text);
    final field = tester.widget<TextField>(find.byType(TextField)).focusNode!;
    for (final k in ['h', 'i', '123', '1', 'abc', 'k']) {
      await _tapKey(tester, k);
      expect(field.hasFocus, isTrue, reason: 'after $k');
      expect(find.byType(VrxKeyboard), findsOneWidget, reason: 'after $k');
    }
    expect(c.text, 'hi1k');
  }, variant: onDevice);

  testWidgets('email: @ and . to hand, no space bar, and no space typed on either keyboard', (tester) async {
    final c = await _field(tester, VrxInputKind.email);
    expect(find.text('@'), findsOneWidget);
    expect(find.text('space'), findsNothing);
    await _tapKey(tester, 'a');
    await _tapKey(tester, '@');
    await _tapKey(tester, 'b');
    await _tapKey(tester, '.');
    expect(c.text, 'a@b.');
    await tester.enterText(find.byType(TextField), 'x y@z');
    expect(c.text, 'xy@z', reason: 'the physical keyboard meets the same filter');
  }, variant: onDevice);

  testWidgets('url: / . and .com to hand, and Enter is Go', (tester) async {
    String? went;
    final c = await _field(tester, VrxInputKind.url, onSubmitted: (t) => went = t);
    await _tapKey(tester, 'v');
    await _tapKey(tester, '.com');
    await _tapKey(tester, '/');
    expect(c.text, 'v.com/');
    expect(find.byIcon(VrxSymbols.arrow_forward), findsOneWidget);
    await tester.tap(find.byIcon(VrxSymbols.arrow_forward));
    await tester.pump();
    expect(went, 'v.com/');
  }, variant: onDevice);

  testWidgets('search: Enter is Search', (tester) async {
    await _field(tester, VrxInputKind.search);
    expect(find.byIcon(VrxSymbols.search), findsOneWidget);
    expect(find.text('space'), findsOneWidget);
  }, variant: onDevice);

  testWidgets('password: the letters, typed as dots', (tester) async {
    final c = await _field(tester, VrxInputKind.password);
    await _tapKey(tester, 'p');
    expect(c.text, 'p');
    expect(tester.widget<TextField>(find.byType(TextField)).obscureText, isTrue);
  }, variant: onDevice);

  testWidgets('number: the pad with large digits, a sign and no point; letters never land', (tester) async {
    String? done;
    final c = await _field(tester, VrxInputKind.number, onSubmitted: (t) => done = t);
    final one = tester.getSize(find.ancestor(of: find.text('1').last, matching: find.byType(VrxPress)));
    for (final k in ['-', '4', '2']) {
      await _tapKey(tester, k);
    }
    expect(c.text, '-42');
    expect(find.text('.'), findsNothing, reason: 'a whole number has no point');
    await tester.enterText(find.byType(TextField), '7a.5');
    expect(c.text, '75');
    await tester.tap(find.byIcon(VrxSymbols.check));
    await tester.pump();
    expect(done, '75');
    // the nuance: a digit is a quarter of the width, a letter a tenth
    await _field(tester, VrxInputKind.text);
    final q = tester.getSize(find.ancestor(of: find.text('q').last, matching: find.byType(VrxPress)));
    expect(one.width, greaterThanOrEqualTo(q.width * 2));
  }, variant: onDevice);

  testWidgets('decimal: the pad with a point', (tester) async {
    final c = await _field(tester, VrxInputKind.decimal);
    for (final k in ['3', '.', '5']) {
      await _tapKey(tester, k);
    }
    expect(c.text, '3.5');
  }, variant: onDevice);

  testWidgets('tel: the phone grid with its letters, + and -; letters never land', (tester) async {
    final c = await _field(tester, VrxInputKind.tel);
    expect(find.text('ABC'), findsOneWidget);
    for (final k in ['+', '9', '1', '-', '#']) {
      await _tapKey(tester, k);
    }
    expect(c.text, '+91-#');
    await tester.enterText(find.byType(TextField), '+1 (555) call');
    expect(c.text, '+1 (555) ');
  }, variant: onDevice);

  testWidgets('every keyboard is one height, so a screen laid out around one fits all', (tester) async {
    double? height;
    for (final kind in VrxInputKind.values.where((k) => k != VrxInputKind.none)) {
      await _field(tester, kind);
      final h = tester.getSize(find.byType(VrxKeyboard)).height;
      height ??= h;
      expect(h, height, reason: '$kind');
    }
  }, variant: onDevice);

  group('wheels write the HTML value', () {
    final forms = {
      VrxInputKind.date: RegExp(r'^\d{4}-\d{2}-\d{2}$'),
      VrxInputKind.time: RegExp(r'^\d{2}:\d{2}$'),
      VrxInputKind.datetime: RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$'),
      VrxInputKind.month: RegExp(r'^\d{4}-\d{2}$'),
      VrxInputKind.week: RegExp(r'^\d{4}-W\d{2}$'),
    };
    for (final MapEntry(key: kind, value: form) in forms.entries) {
      testWidgets('$kind: wheels, and Done writes its form and submits', (tester) async {
        String? done;
        final c = await _field(tester, kind, onSubmitted: (t) => done = t);
        expect(find.byType(VrxWheel), findsWidgets);
        expect(c.text, isEmpty, reason: 'nothing is written until a wheel moves or Done');
        await tester.tap(find.byIcon(VrxSymbols.check));
        await tester.pump();
        expect(c.text, matches(form));
        expect(done, c.text);
      }, variant: onDevice);
    }

    testWidgets('they start from the value the field holds', (tester) async {
      for (final (kind, value) in [
        (VrxInputKind.date, '2031-02-28'),
        (VrxInputKind.time, '07:05'),
        (VrxInputKind.datetime, '2030-12-31T23:59'),
        (VrxInputKind.month, '2029-06'),
        // 2026 starts on a Thursday: it has a 53rd week
        (VrxInputKind.week, '2026-W53'),
      ]) {
        final c = await _field(tester, kind, text: value);
        await tester.tap(find.byIcon(VrxSymbols.check));
        await tester.pump();
        expect(c.text, value, reason: '$kind');
      }
    }, variant: onDevice);

    testWidgets('a turned wheel writes at once', (tester) async {
      final c = await _field(tester, VrxInputKind.time, text: '10:00');
      await tester.drag(find.byType(VrxWheel).first, const Offset(0, -60));
      await tester.pumpAndSettle();
      expect(c.text, matches(RegExp(r'^1[1-9]:00$')));
    }, variant: onDevice);

    testWidgets('datetime shows the date, then the time', (tester) async {
      await _field(tester, VrxInputKind.datetime);
      expect(find.byType(VrxWheel), findsNWidgets(3));
      await _tapKey(tester, 'Time');
      expect(find.byType(VrxWheel), findsNWidgets(2));
    }, variant: onDevice);
  });

  group('the gamepad', () {
    testWidgets('the D-pad moves focus, A activates, B goes back', (tester) async {
      var pressed = '';
      var back = 0;
      late BuildContext ctx;
      await _host(
        tester,
        VrxBackOffer(
          onBack: () => back++,
          child: Builder(builder: (context) {
            ctx = context;
            return Column(mainAxisSize: MainAxisSize.min, children: [
              TextButton(autofocus: true, onPressed: () => pressed = 'one', child: const Text('one')),
              TextButton(onPressed: () => pressed = 'two', child: const Text('two')),
            ]);
          }),
        ),
      );
      expect(VrxKeyboardSlot.show(ctx, kind: VrxInputKind.gamepad), isTrue);
      await tester.pump();
      await tester.pump();
      expect(find.text('Start'), findsOneWidget);
      Future<void> tap(String? label, [Finder? at]) async {
        final g = await tester.startGesture(tester.getCenter(at ?? find.text(label!).last));
        await tester.pump();
        await g.up();
        await tester.pump();
      }

      await tap(null, find.byIcon(VrxSymbols.keyboard_arrow_down));
      await tap('A');
      expect(pressed, 'two', reason: 'Down moved focus to the second button; A activated it');
      await tap('B');
      expect(back, 1);
      VrxKeyboardSlot.dismiss(ctx);
      await tester.pump();
      await tester.pump();
      expect(find.text('Start'), findsNothing);
    }, variant: onDevice);

    testWidgets('a gamepad field brings it up, and A submits the field', (tester) async {
      String? done;
      final c = await _field(tester, VrxInputKind.gamepad, text: 'go', onSubmitted: (t) => done = t);
      expect(find.text('Select'), findsOneWidget);
      final g = await tester.startGesture(tester.getCenter(find.text('A').last));
      await tester.pump();
      await g.up();
      await tester.pump();
      expect(done, 'go');
      expect(c.text, 'go');
    }, variant: onDevice);
  });

  group('programmatic, the exceptional case', () {
    testWidgets('dismiss puts a field\'s keyboard away until the field is tapped', (tester) async {
      await _field(tester, VrxInputKind.text);
      expect(find.byType(VrxKeyboard), findsOneWidget);
      VrxKeyboardSlot.dismiss(tester.element(find.byType(VrxTextField)));
      await tester.pump();
      await tester.pump();
      expect(find.byType(VrxKeyboard), findsNothing, reason: 'the field kept focus and did not take it back');
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.pump();
      expect(find.byType(VrxKeyboard), findsOneWidget);
    }, variant: onDevice);

    testWidgets('show brings a text keyboard to an editor of its own, whatever is plugged in', (tester) async {
      final typed = <String>[];
      late BuildContext ctx;
      await _host(tester, Builder(builder: (context) {
        ctx = context;
        return const SizedBox.expand();
      }), keyboard: true);
      VrxKeyboardSlot.show(ctx, kind: VrxInputKind.number, editor: _Recorder(typed));
      await tester.pump();
      await tester.pump();
      await _tapKey(tester, '7');
      expect(typed, ['7']);
    }, variant: onDevice);
  });

  testWidgets('a field with a physical keyboard plugged in brings none, of any kind', (tester) async {
    for (final kind in [VrxInputKind.number, VrxInputKind.date, VrxInputKind.gamepad]) {
      final c = TextEditingController();
      await _host(tester, Center(child: VrxTextField(controller: c, kind: kind, autofocus: true)), keyboard: true);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();
      expect(find.byType(VrxKeyboard), findsNothing, reason: '$kind');
    }
  }, variant: onDevice);
}

class _Recorder implements VrxTextEditor {
  _Recorder(this.typed);

  final List<String> typed;

  @override
  bool get multiline => false;

  @override
  String get text => typed.join();

  @override
  void type(String text) => typed.add(text);

  @override
  void replace(String text) => typed
    ..clear()
    ..add(text);

  @override
  void backspace() {}

  @override
  void enter() {}
}
