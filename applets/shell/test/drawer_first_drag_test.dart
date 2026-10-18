import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_check/vrx_check.dart';
import 'package:vrx_kit/vrx_kit.dart';

import 'package:shell_applet/main.dart';
import 'package:shell_applet/state.dart';

/// The owner, 2026-10-18: after the drawer is dismissed (and after boot),
/// the FIRST swipe down on the strip goes unrecognized; the second opens
/// it. On the bench the same happened with the first drag of a session.
void main() {
  ShellModel model() => ShellModel(now: () => DateTime(2026, 10, 18, 18, 0).millisecondsSinceEpoch)..clockValid = true;

  testWidgets('the first drag after mount pulls the drawer down', (tester) async {
    await mountApplet(tester, ShellApplet(model()));
    await settleMotion(tester);
    final gestures = await tester.startGesture(Offset(240, 16));
    for (var y = 40; y <= 400; y += 40) {
      await gestures.moveBy(const Offset(0, 40));
      await tester.pump();
    }
    await tester.pump();
    expect(find.text('Wi-Fi'), findsOneWidget, reason: 'the drawer follows the first drag');
    await gestures.up();
    await settleMotion(tester);
    expect(find.text('Wi-Fi'), findsOneWidget, reason: 'let go open stays open');
  });

  testWidgets('after the drawer is shut the first drag opens it again', (tester) async {
    await mountApplet(tester, ShellApplet(model()));
    await settleMotion(tester);
    // open once, the way a person does
    var g = await tester.startGesture(Offset(240, 16));
    for (var i = 0; i < 9; i++) {
      await g.moveBy(const Offset(0, 40));
      await tester.pump();
    }
    await g.up();
    await settleMotion(tester);
    expect(find.text('Wi-Fi'), findsOneWidget);
    // shut it through the model (a scrim tap's outcome)
    (tester.state(find.byType(VrxPull)) as dynamic).widget.onIntent(false);
    await settleMotion(tester);
    expect(find.text('Wi-Fi'), findsNothing, reason: 'shut');
    // the first drag after the shut: this is the one the owner loses
    g = await tester.startGesture(Offset(240, 16));
    for (var i = 0; i < 9; i++) {
      await g.moveBy(const Offset(0, 40));
      await tester.pump();
    }
    await tester.pump();
    expect(find.text('Wi-Fi'), findsOneWidget, reason: 'the first drag after a shut opens the drawer');
    await g.up();
    await settleMotion(tester);
  });
}
