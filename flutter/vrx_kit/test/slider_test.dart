import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

/// The slider's contract: a drag reports as it moves and once at rest, a
/// tap jumps, the arrow keys step (its key form), never past its ends.
void main() {
  Future<(List<int>, List<int>)> mount(WidgetTester tester, int value) async {
    final moved = <int>[], rested = <int>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 400,
            child: VrxSlider(label: 'Brightness', value: value, onChanged: moved.add, onChangeEnd: rested.add),
          ),
        ),
      ),
    ));
    return (moved, rested);
  }

  testWidgets('a drag reports as it moves, and once where it stops', (tester) async {
    final (moved, rested) = await mount(tester, 50);
    final box = tester.getRect(find.byType(VrxSlider));
    final g = await tester.startGesture(box.center);
    await g.moveBy(const Offset(40, 0));
    await g.moveBy(const Offset(400, 0));
    await g.up();
    await tester.pump();
    expect(moved, isNotEmpty);
    expect(moved.last, 100, reason: 'past the end is the end');
    expect(rested, [100]);
  });

  testWidgets('a tap jumps to where it landed', (tester) async {
    final (_, rested) = await mount(tester, 50);
    final box = tester.getRect(find.byType(VrxSlider));
    await tester.tapAt(Offset(box.left + 1, box.center.dy));
    expect(rested, [0]);
  });

  testWidgets('the arrow keys step it, and stop at its ends', (tester) async {
    final (_, rested) = await mount(tester, 95);
    // Tab gives it focus (keyboard focus shows the ring)
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(rested, [100]);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(rested, [100], reason: 'already at the end: nothing to report');
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    expect(rested.last, 0);
  });
}
