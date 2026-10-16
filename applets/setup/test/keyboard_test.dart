import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' hide Intent;
import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_check/vrx_check.dart';
import 'package:vrx_kit/vrx_kit.dart';

import 'package:setup_applet/main.dart';
import 'package:setup_applet/state.dart';

/// The device name field brings the on-screen keyboard up on the panel
/// Setup first runs on, with no physical keyboard plugged in (the owner,
/// 2026-10-15: it did not on the board), and keeps it away when one is.
void main() {
  Future<ScreenSettings> settings(WidgetTester tester, {required bool keyboard}) async {
    final dir = await tester.runAsync(() => Directory.systemTemp.createTemp('vrx-setup')) as Directory;
    await tester.runAsync(() async {
      await File('${dir.path}/screen.conf').writeAsString('');
      await File('${dir.path}/screen').writeAsString('touch=1\nkeyboard=${keyboard ? 1 : 0}\n');
    });
    return ScreenSettings(dir: dir.path, capsPath: '${dir.path}/screen', backlights: '${dir.path}/none');
  }

  Future<void> walk(WidgetTester tester, {required SetupStep from, required bool keyboard}) async {
    final d = allDisplays.firstWhere((x) => x.name == 'disp28a');
    tester.view.physicalSize = Size(d.width, d.height);
    tester.view.devicePixelRatio = d.pixelRatio;
    addTearDown(tester.view.reset);
    final s = await settings(tester, keyboard: keyboard);
    final model = SetupModel()..step = from;
    final actions = StreamController<SetupAction>();
    addTearDown(actions.close);
    await tester.runAsync(() async {
      await tester.pumpWidget(AppletHost(applet: SetupApplet(model), screen: s, actions: actions.stream));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    // Welcome's Accept, through the store as on the board, and the slide in
    if (from == SetupStep.licence) actions.add(SetupAction.next);
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(model.step, SetupStep.name);
  }

  for (final from in [SetupStep.name, SetupStep.licence]) {
    testWidgets('the name field brings the keyboard up, from ${from.name}', (tester) async {
      await walk(tester, from: from, keyboard: false);
      expect(find.byType(VrxKeyboard), findsOneWidget);
      await tester.tap(find.text('k'));
      await tester.pump();
      expect(tester.widget<TextField>(find.byType(TextField)).controller?.text, 'k', reason: 'the keys type into the name');
    }, variant: onDevice);
  }

  testWidgets('with a keyboard plugged in the name field takes none', (tester) async {
    await walk(tester, from: SetupStep.licence, keyboard: true);
    expect(find.byType(VrxKeyboard), findsNothing);
  }, variant: onDevice);
}
