import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

/// G021 (plan 0011 D3): the one periodic source rests while the applet is
/// hidden (behind another, or under a dark screen) and ticks once at once
/// when it is back; the background form keeps going.
// the states in the order the engine reports them (the framework fills in
// the ones between; AppLifecycleListener asserts on a skipped one)
void hide(WidgetTester tester) {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
}

void show(WidgetTester tester) {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
}

void main() {
  testWidgets('a ticker rests while hidden and catches up when shown', (tester) async {
    var ticks = 0;
    final t = VrxTicker(const Duration(seconds: 1), () => ticks++);
    addTearDown(t.cancel);
    await tester.pump(const Duration(seconds: 3));
    expect(ticks, 3);
    hide(tester);
    await tester.pump(const Duration(seconds: 10));
    expect(ticks, 3, reason: 'nothing while hidden');
    expect(t.active, isFalse);
    show(tester);
    expect(ticks, 4, reason: 'one tick at once on the way back');
    await tester.pump(const Duration(seconds: 2));
    expect(ticks, 6);
    t.cancel();
    await tester.pump(const Duration(seconds: 2));
    expect(ticks, 6);
  });

  testWidgets('a background ticker keeps ticking while hidden', (tester) async {
    var ticks = 0;
    final t = VrxTicker.background(const Duration(seconds: 1), () => ticks++);
    addTearDown(t.cancel);
    hide(tester);
    await tester.pump(const Duration(seconds: 3));
    expect(ticks, 3);
    show(tester);
    t.cancel();
  });
}
