import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

/// The modal contracts: cancel left and read first; the destructive
/// act last and filled; the act is named ("Delete"), never "OK"; the
/// message says what will go; three acts is refused — a menu is a
/// screen.
void main() {
  Future<void> pumpConfirm(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VrxConfirm(
            title: 'Delete alarm?',
            message: 'The 07:00 alarm will be deleted.',
            cancelLabel: 'Cancel',
            act: VrxModalAction(label: 'Delete'),
          ),
        ),
      ),
    );
  }

  testWidgets('cancel is left, the act is right and filled',
      (tester) async {
    await pumpConfirm(tester);
    final cancel = tester.getCenter(find.text('Cancel'));
    final act = tester.getCenter(find.text('Delete'));
    expect(cancel.dx, lessThan(act.dx), reason: 'the safe answer is first');
  });

  testWidgets('the message says what will go', (tester) async {
    await pumpConfirm(tester);
    expect(find.textContaining('will be deleted'), findsOneWidget);
    expect(find.text('OK'), findsNothing, reason: 'name the act, never OK');
  });

  testWidgets('a modal with no act is the message alone', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VrxConfirm(
            title: 'Copied',
            message: 'The card is unmounted.',
            cancelLabel: 'Close',
          ),
        ),
      ),
    );
    expect(find.text('Close'), findsOneWidget);
    expect(find.textContaining('unmounted'), findsOneWidget);
  });

  testWidgets('two acts stack under cancel, the last filled',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VrxAsk(
            title: 'Update?',
            message: 'The device restarts to apply it.',
            cancelLabel: 'Cancel',
            actions: [
              VrxModalAction(label: 'Later'),
              VrxModalAction(label: 'Update'),
            ],
          ),
        ),
      ),
    );
    final cancel = tester.getCenter(find.text('Cancel')).dy;
    final later = tester.getCenter(find.text('Later')).dy;
    final update = tester.getCenter(find.text('Update')).dy;
    expect(later, greaterThan(cancel), reason: 'acts stack under cancel');
    expect(update, greaterThan(later), reason: 'the last act is last');
  });

  test('three acts is refused — a menu is a screen', () {
    expect(
      () => VrxAsk(
        title: 't',
        message: 'm',
        cancelLabel: 'Cancel',
        actions: const [
          VrxModalAction(label: 'a'),
          VrxModalAction(label: 'b'),
          VrxModalAction(label: 'c'),
        ],
      ),
      throwsA(isA<AssertionError>()),
    );
  });
}
