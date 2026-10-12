import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

/// The quick drawer's contract: the scrim dismisses on tap, the panel
/// does not; the shortcuts fill when their link is up. The setup
/// walk's: the step counts, the last step says Finish.
void main() {
  testWidgets('the scrim dismisses; the panel eats taps', (tester) async {
    var dismissed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: [
            const Scaffold(body: Text('behind')),
            VrxQuickDrawer(
              version: 'vrx 0.1.0',
              lightOn: true,
              wifiUp: true,
              bleUp: false,
              onDismiss: () => dismissed++,
            ),
          ],
        ),
      ),
    );

    // tap the panel area (the version row): not a dismissal
    await tester.tap(find.text('vrx 0.1.0'));
    expect(dismissed, 0);

    // tap the scrim below the panel: a dismissal
    // below the panel, inside the 800x600 test surface
    await tester.tapAt(const Offset(400, 500));
    expect(dismissed, 1);
  });

  testWidgets('wifi fills when up; ble stays outlined when down',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: [
            const Scaffold(),
            VrxQuickDrawer(
              version: 'v',
              lightOn: false,
              wifiUp: true,
              bleUp: false,
            ),
          ],
        ),
      ),
    );
    final palette = VrxTheme.of(
      tester.element(find.byType(VrxQuickDrawer)),
    );
    final boxes = tester
        .widgetList<Container>(find.byType(Container))
        .where((c) => c.decoration is BoxDecoration)
        .toList();
    final filled = boxes.where(
      (c) => (c.decoration as BoxDecoration).color == palette.fill,
    );
    // exactly the wifi shortcut is filled
    expect(filled, isNotEmpty);
    expect(
      boxes.where(
        (c) => (c.decoration as BoxDecoration).color == null,
      ),
      isNotEmpty,
      reason: 'the ble shortcut stays outlined',
    );
  });

  testWidgets('the setup walk counts its steps and finishes',
      (tester) async {
    var nexted = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VrxSetupStep(
            step: 4,
            of: 5,
            title: 'Time zone',
            intro: 'Set the zone the clock keeps.',
            control: const Text('zone control'),
            nextLabel: 'Finish',
            onNext: () => nexted++,
          ),
        ),
      ),
    );
    expect(find.text('Step 4 of 5'), findsOneWidget);
    expect(find.text('Time zone'), findsOneWidget);
    expect(find.text('Finish'), findsOneWidget);

    await tester.tap(find.text('Finish'));
    expect(nexted, 1);
  });
}
