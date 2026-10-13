import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

/// plan 0011 D8: the segmented control takes the arrows, frames its
/// choice, and fits its widest label by shrinking all alike.
void main() {
  Future<List<int>> pump(WidgetTester tester, {double width = 400, List<String>? labels}) async {
    final picked = <int>[];
    var selected = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            child: StatefulBuilder(
              builder: (context, set) => VrxSegmented(
                labels: labels ?? const ['Day', 'Week', 'Month'],
                selected: selected,
                onSelected: (i) => set(() {
                  picked.add(i);
                  selected = i;
                }),
              ),
            ),
          ),
        ),
      ),
    ));
    return picked;
  }

  testWidgets('the arrows move the choice', (tester) async {
    final picked = await pump(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    for (final k in [LogicalKeyboardKey.arrowRight, LogicalKeyboardKey.arrowRight, LogicalKeyboardKey.arrowRight, LogicalKeyboardKey.arrowLeft]) {
      await tester.sendKeyEvent(k);
      await tester.pump();
    }
    expect(picked, [1, 2, 1], reason: 'stops at the last cell');
  });

  testWidgets('a narrow row shrinks every label alike and cuts none', (tester) async {
    await pump(tester, width: 120, labels: const ['Pomodoro', 'Precise']);
    final a = tester.widget<Text>(find.text('Pomodoro')).style!.fontSize!;
    final b = tester.widget<Text>(find.text('Precise')).style!.fontSize!;
    expect(a, b);
    expect(tester.takeException(), isNull, reason: 'no overflow');
    final cell = tester.getSize(find.text('Pomodoro')).width;
    expect(cell, lessThanOrEqualTo(60));
  });
}
