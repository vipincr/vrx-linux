import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

/// The status strip's contract: facts in, glyphs out; ble hidden when
/// down (an always-present glyph says nothing); "--:--" when the
/// clock is unset; "~" while the battery reading is an estimate; the
/// bolt when charging; five battery levels.
void main() {
  Future<void> pumpFacts(WidgetTester tester, VrxStatusFacts facts) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: VrxStatusStrip(facts: facts)),
      ),
    );
  }

  testWidgets('ble is hidden when down, present when up', (tester) async {
    await pumpFacts(tester, const VrxStatusFacts());
    expect(find.byIcon(Icons.bluetooth), findsNothing);

    await pumpFacts(tester, const VrxStatusFacts(bleUp: true));
    expect(find.byIcon(Icons.bluetooth), findsOneWidget);
  });

  testWidgets('the clock reads --:-- when unset', (tester) async {
    await pumpFacts(tester, const VrxStatusFacts());
    expect(find.text('--:--'), findsOneWidget);
  });

  testWidgets('the battery estimates with ~ and charges with a bolt',
      (tester) async {
    await pumpFacts(
      tester,
      const VrxStatusFacts(batteryLevel: 41, batteryEstimated: true),
    );
    expect(find.text('~41%'), findsOneWidget);

    await pumpFacts(
      tester,
      const VrxStatusFacts(batteryLevel: 41, batteryCharging: true),
    );
    expect(find.byIcon(Icons.bolt), findsOneWidget);
    expect(find.text('41%'), findsOneWidget);
  });

  testWidgets('back is offered only when there is somewhere to go',
      (tester) async {
    await pumpFacts(tester, const VrxStatusFacts());
    expect(find.byIcon(Icons.arrow_back), findsNothing);

    await pumpFacts(
      tester,
      VrxStatusFacts(showBack: true, onBack: () {}),
    );
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);
  });

  testWidgets('the five battery levels bucket at the surveyed cuts',
      (tester) async {
    Future<IconData> glyphAt(int level) async {
      await pumpFacts(tester, VrxStatusFacts(batteryLevel: level));
      final icon = tester.widget<Icon>(
        find.descendant(
          of: find.byType(VrxStatusStrip),
          matching: find.byType(Icon),
        ).last,
      );
      return icon.icon!;
    }

    expect(await glyphAt(89), Icons.battery_full);
    expect(await glyphAt(64), Icons.battery_5_bar);
    expect(await glyphAt(39), Icons.battery_3_bar);
    expect(await glyphAt(14), Icons.battery_2_bar);
    expect(await glyphAt(5), Icons.battery_0_bar);
  });
}
