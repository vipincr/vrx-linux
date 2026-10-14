import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
    expect(find.byIcon(VrxSymbols.bluetooth), findsNothing);

    await pumpFacts(tester, const VrxStatusFacts(bleUp: true));
    expect(find.byIcon(VrxSymbols.bluetooth), findsOneWidget);
  });

  testWidgets('the network glyph says how the device is connected', (tester) async {
    // nothing joined, no cable: Wi-Fi's own off glyph
    await pumpFacts(tester, const VrxStatusFacts());
    expect(find.byIcon(VrxSymbols.wifi_off), findsOneWidget);
    expect(find.byIcon(VrxSymbols.lan), findsNothing);
    // a cable up and Wi-Fi off: the wired glyph alone (wifi_off would read
    // as offline)
    await pumpFacts(tester, const VrxStatusFacts(wiredUp: true));
    expect(find.byIcon(VrxSymbols.lan), findsOneWidget);
    expect(find.byIcon(VrxSymbols.wifi_off), findsNothing);
    // both up: both glyphs
    await pumpFacts(tester, const VrxStatusFacts(wiredUp: true, wifiUp: true));
    expect(find.byIcon(VrxSymbols.lan), findsOneWidget);
    expect(find.byIcon(VrxSymbols.wifi), findsOneWidget);
  });

  testWidgets('a narrow strip drops the percent, then Bluetooth, never the camera or the links', (tester) async {
    tester.view.physicalSize = const Size(300, 60);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpFacts(
      tester,
      const VrxStatusFacts(
          clockText: '23:59', cameraOn: true, wiredUp: true, wifiUp: true, bleUp: true, batteryLevel: 100),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('100%'), findsNothing);
    expect(find.byIcon(VrxSymbols.photo_camera), findsOneWidget);
    expect(find.byIcon(VrxSymbols.lan), findsOneWidget);
    expect(find.byIcon(VrxSymbols.wifi), findsOneWidget);
    // with room, everything shows
    tester.view.physicalSize = const Size(1000, 60);
    await pumpFacts(
      tester,
      const VrxStatusFacts(
          clockText: '23:59', cameraOn: true, wiredUp: true, wifiUp: true, bleUp: true, batteryLevel: 100),
    );
    expect(find.text('100%'), findsOneWidget);
    expect(find.byIcon(VrxSymbols.bluetooth), findsOneWidget);
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
    expect(find.byIcon(VrxSymbols.bolt), findsOneWidget);
    expect(find.text('41%'), findsOneWidget);
  });

  testWidgets('back is offered only when there is somewhere to go',
      (tester) async {
    await pumpFacts(tester, const VrxStatusFacts());
    expect(find.byIcon(VrxSymbols.arrow_back), findsNothing);

    await pumpFacts(
      tester,
      VrxStatusFacts(showBack: true, onBack: () {}),
    );
    expect(find.byIcon(VrxSymbols.arrow_back), findsOneWidget);
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

    expect(await glyphAt(89), VrxSymbols.battery_full);
    expect(await glyphAt(64), VrxSymbols.battery_5_bar);
    expect(await glyphAt(39), VrxSymbols.battery_3_bar);
    expect(await glyphAt(14), VrxSymbols.battery_2_bar);
    expect(await glyphAt(5), VrxSymbols.battery_0_bar);
  });

  // plan 0011 D8: fixed slots, and no state in colour alone
  testWidgets('the clock does not move when Back appears', (tester) async {
    await pumpFacts(tester, const VrxStatusFacts(clockText: '13:05'));
    final without = tester.getTopLeft(find.text('13:05'));
    await pumpFacts(tester, VrxStatusFacts(clockText: '13:05', showBack: true, onBack: () {}));
    expect(tester.getTopLeft(find.text('13:05')), without);
  });

  testWidgets('Wi-Fi down is its own glyph, not a fainter one', (tester) async {
    await pumpFacts(tester, const VrxStatusFacts(wifiUp: true));
    expect(find.byIcon(VrxSymbols.wifi), findsOneWidget);
    await pumpFacts(tester, const VrxStatusFacts());
    expect(find.byIcon(VrxSymbols.wifi_off), findsOneWidget);
    expect(find.byIcon(VrxSymbols.wifi), findsNothing);
  });

  testWidgets('a notice takes the day\'s place', (tester) async {
    await pumpFacts(tester, const VrxStatusFacts(clockText: '13:05', dateText: 'Tue 13 Oct', notice: 'Recorder stopped.'));
    expect(find.text('Recorder stopped.'), findsOneWidget);
    expect(find.text('Tue 13 Oct'), findsNothing);
  });

  // the bench, disp28a: "Wed 1…"; a cut day must not happen (rule 20)
  testWidgets('a narrow strip drops words from the front of the day, never cuts one', (tester) async {
    Future<void> at(double width) => tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: width,
                child: const VrxStatusStrip(facts: VrxStatusFacts(clockText: '13:05', dateText: 'Wed 14 Oct', wifiUp: true)),
              ),
            ),
          ),
        ));
    await at(800);
    expect(find.text('Wed 14 Oct'), findsOneWidget);
    // narrow enough that the whole day cannot sit beside the clock
    for (final w in [400.0, 340.0, 300.0]) {
      await at(w);
      final shown = [for (final t in tester.widgetList<Text>(find.byType(Text))) t.data].whereType<String>().toList();
      final cut = tester.renderObjectList<RenderParagraph>(find.byType(RichText)).where((p) => p.didExceedMaxLines);
      expect(cut, isEmpty, reason: 'width $w: $shown');
      expect(shown.where((t) => t != '13:05').every((t) => 'Wed 14 Oct'.endsWith(t)), isTrue, reason: 'width $w: $shown');
    }
  });
}
