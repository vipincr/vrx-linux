import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_check/vrx_check.dart';
import 'package:vrx_kit/src/screens.dart';
import 'package:vrx_kit/vrx_kit.dart';

import 'package:shell_applet/main.dart';
import 'package:shell_applet/state.dart';

/// The owner, 2026-10-18: after the drawer is dismissed (and after boot),
/// the FIRST swipe down on the strip goes unrecognized; the second opens
/// it. Root cause (found on the 0136 board and in this harness, probes in
/// hand): the drag recognizer died when the engaged layer's mounting
/// shifted the strip's element index in VrxPull's stack and Flutter
/// replaced the element positionally — START fired, then silence; a flick
/// that finished inside one frame survived, which is why the second swipe
/// worked. The stack's children are keyed now, so the contact that
/// starts on the strip owns its whole life.
///
/// The drawer's shortcuts are icon boxes with semantic labels (no Text),
/// so the assertions read the panel's rect: on screen when open, above
/// the screen's top edge when shut.
void main() {
  ShellModel model() => ShellModel(
          now: () => DateTime(2026, 10, 21, 12, 0).millisecondsSinceEpoch)
      ..clockValid = true;

  // the panel's presence: the engaged layer is mounted while the drawer
  // is open or moving, and unmounts once it is shut (its translation is
  // paint-only, so a rect cannot see it)

  Future<void> dragDown(WidgetTester tester) async {
    final g = await tester.startGesture(const Offset(240, 30));
    for (var i = 0; i < 10; i++) {
      await g.moveBy(const Offset(0, 45));
      await tester.pump(const Duration(milliseconds: 30));
    }
    await g.up();
    await settleMotion(tester);
  }

  testWidgets('the first drag after mount pulls the drawer down', (tester) async {
    tester.view.physicalSize = const Size(480, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await mountApplet(tester, ShellApplet(model()));
    await settleMotion(tester);
    await dragDown(tester);
    expect(find.byType(VrxQuickDrawer), findsOneWidget,
        reason: 'the drawer is open after the first drag');
  });

  testWidgets('after the drawer is shut the first drag opens it again',
      (tester) async {
    tester.view.physicalSize = const Size(480, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await mountApplet(tester, ShellApplet(model()));
    await settleMotion(tester);
    // open once, the way a person does
    await dragDown(tester);
    expect(find.byType(VrxQuickDrawer), findsOneWidget, reason: 'open');
    // shut it the way a person does: drag the panel back up (the scrim
    // tap's _finish(false) is the same spring, and onIntent alone does
    // not spring — the model is not wired in this harness)
    final g = await tester.startGesture(const Offset(240, 300));
    for (var i = 0; i < 10; i++) {
      await g.moveBy(const Offset(0, -45));
      await tester.pump(const Duration(milliseconds: 30));
    }
    await g.up();
    await settleMotion(tester);
    expect(find.byType(VrxQuickDrawer), findsNothing,
        reason: 'shut: the layer unmounts');
    // the first drag after the shut: this is the one the owner loses
    await dragDown(tester);
    expect(find.byType(VrxQuickDrawer), findsOneWidget,
        reason: 'the first drag after a shut opens the drawer');
  });
}
