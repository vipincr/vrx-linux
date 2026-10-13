import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
            act: const VrxModalAction(label: 'Delete'),
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
            actions: const [
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

  // G020 (plan 0011 D1): Back belongs to the topmost route. With a
  // confirm open, the strip's Back, Escape and the mouse's back button
  // answer Cancel and close the modal; the screen under it stays.
  group('a modal owns Back', () {
    late int screenBacks;
    Future<bool?> Function()? open;

    Future<void> pumpScreen(WidgetTester tester) async {
      screenBacks = 0;
      await tester.pumpWidget(MaterialApp(
        builder: (context, child) => VrxInputRoot(child: child!),
        home: VrxBackOffer(
          onBack: () => screenBacks++,
          child: Scaffold(
            body: Builder(builder: (context) {
              open = () => vrxConfirm(context, title: 'Delete alarm?', message: 'The 07:00 alarm will be deleted.', act: 'Delete');
              return const SizedBox.expand();
            }),
          ),
        ),
      ));
    }

    Future<Future<bool?>> opened(WidgetTester tester) async {
      final answer = open!();
      await tester.pumpAndSettle();
      expect(find.text('Delete alarm?'), findsOneWidget);
      return answer;
    }

    testWidgets("the strip's Back answers Cancel", (tester) async {
      await pumpScreen(tester);
      final answer = await opened(tester);
      expect(VrxBack.invoke(), isTrue);
      await tester.pumpAndSettle();
      expect(find.text('Delete alarm?'), findsNothing);
      expect(screenBacks, 0, reason: 'the screen under the modal stays');
      expect(await answer, isFalse);
      // with the modal gone, Back is the screen's again
      VrxBack.invoke();
      expect(screenBacks, 1);
    });

    testWidgets('Escape answers Cancel', (tester) async {
      await pumpScreen(tester);
      final answer = await opened(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Delete alarm?'), findsNothing);
      expect(screenBacks, 0);
      expect(await answer, isFalse);
    });

    testWidgets("the mouse's back button answers Cancel", (tester) async {
      await pumpScreen(tester);
      final answer = await opened(tester);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse, buttons: kBackMouseButton);
      // on the dialog itself: a press on the scrim would be Cancel anyway
      await mouse.down(tester.getCenter(find.text('Delete alarm?')));
      await mouse.up();
      await tester.pumpAndSettle();
      expect(find.text('Delete alarm?'), findsNothing);
      expect(screenBacks, 0);
      expect(await answer, isFalse);
    });

    testWidgets('the act answers true', (tester) async {
      await pumpScreen(tester);
      final answer = await opened(tester);
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(await answer, isTrue);
    });
  });
}
