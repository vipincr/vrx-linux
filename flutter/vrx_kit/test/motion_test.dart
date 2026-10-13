import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

/// The motion presets are the only sanctioned motion: if one stops
/// animating (a curve that never progresses, a transition that jumps),
/// every applet moves wrong at once. These tests pump the routes and
/// assert the transition actually runs — the host-side proof of the
/// animation contract (the vsync side is the compositor's, part E).
void main() {
  testWidgets('Motion.push slides the screen in from the right',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Text('home')));
    final context = tester.element(find.text('home'));
    Navigator.of(context).push(
      Motion.push(const Scaffold(body: Text('pushed'))),
    );

    // the first two pumps install the route and build its first
    // frame: the new screen sits a full screen-width to the right
    // (slides in, never jumps)
    await tester.pump();
    await tester.pump();
    final offscreen = tester.getTopLeft(find.text('pushed')).dx;
    expect(offscreen, greaterThan(600), reason: 'starts off-screen');

    // mid-transition it has moved but not arrived
    await tester.pump(const Duration(milliseconds: 120));
    final midway = tester.getTopLeft(find.text('pushed')).dx;
    expect(midway, lessThan(offscreen));
    expect(midway, greaterThan(0));

    // settled: arrived
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('pushed')).dx, closeTo(0, 0.5));
  });

  testWidgets('Motion.modal fades in over a dimmed field', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Text('home')));
    final context = tester.element(find.text('home'));
    Navigator.of(context).push(
      Motion.modal(context, const Scaffold(body: Text('modal'))),
    );

    // two pumps: install, then build the first (still fading) frame
    await tester.pump();
    await tester.pump();
    FadeTransition findFade() => tester
        .widget<FadeTransition>(
          find.ancestor(of: find.text('modal'), matching: find.byType(FadeTransition)).first,
        );
    final early = findFade().opacity.value;
    expect(early, lessThan(1.0), reason: 'a modal fades in, never pops');

    await tester.pumpAndSettle();
    expect(findFade().opacity.value, 1.0);
    expect(find.text('modal'), findsOneWidget);
  });
}
