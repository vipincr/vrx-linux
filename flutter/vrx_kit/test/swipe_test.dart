import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

/// The strip's gestures: a swipe down or up past the threshold, and a tap
/// that reaches the control under it without counting as a swipe (the
/// owner: a tap meant for Back opened the drawer).
void main() {
  testWidgets('a swipe opens and closes; a tap reaches Back; a nudge does nothing', (tester) async {
    var down = 0, up = 0, back = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: VrxSwipe(
          onDown: () => down++,
          onUp: () => up++,
          child: SizedBox(
            height: 80,
            width: double.infinity,
            child: Row(children: [
              VrxPress(onTap: () => back++, child: const SizedBox(width: 60, height: 60, child: Text('Back'))),
              const Spacer(),
            ]),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Back'));
    await tester.pump();
    expect((back, down, up), (1, 0, 0), reason: 'a tap is Back, never the drawer');

    await tester.fling(find.byType(VrxSwipe), const Offset(0, 60), 800);
    await tester.pump();
    expect(down, 1);
    await tester.fling(find.byType(VrxSwipe), const Offset(0, -60), 800);
    await tester.pump();
    expect(up, 1);

    // under the 2.5mm travel: nothing
    await tester.drag(find.byType(VrxSwipe), const Offset(0, 5));
    await tester.pump();
    expect((down, up), (1, 1));
    // sideways: not a vertical swipe
    await tester.fling(find.byType(VrxSwipe), const Offset(80, 30), 800);
    await tester.pump();
    expect((down, up), (1, 1));
    // a swipe that starts on Back is a swipe, and not a press of Back
    await tester.fling(find.text('Back'), const Offset(0, 60), 800);
    await tester.pump();
    expect((back, down), (1, 2));
  });
}
