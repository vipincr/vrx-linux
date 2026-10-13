import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_check/vrx_check.dart';
import 'package:vrx_kit/vrx_kit.dart';

/// A one-screen applet around [body], for feeding the rules.
class _Screen extends Applet<int, int, int> {
  _Screen(this.body);

  final Widget Function(BuildContext) body;

  @override
  int get initial => 0;
  @override
  int get bootAction => 0;
  @override
  int reduce(int state, int action) => 0;
  @override
  int get snapshot => 0;
  @override
  Widget build(BuildContext context, int view) => Scaffold(body: SafeArea(child: Builder(builder: body)));
}

Future<List<String>> rules(WidgetTester tester, Widget Function(BuildContext) body) async =>
    [for (final i in await checkApplet(tester, _Screen(body))) i.rule];

void main() {
  testWidgets('a clean list screen breaks nothing', (tester) async {
    final found = await rules(
      tester,
      (c) => VrxList(children: [
        const VrxHeader(title: 'Alarms', onBack: null),
        VrxRow(label: 'Repeat', value: 'Weekdays', onTap: () {}),
        VrxRow(label: 'Snooze', value: 'On', onTap: () {}),
      ]),
    );
    expect(found, isEmpty);
  });

  testWidgets('the photographed timer: stops over the centre, a word broken, a small control', (tester) async {
    final found = await rules(
      tester,
      (c) => Column(children: [
        // "Pomodoro" in a box too narrow for it
        SizedBox(width: 60, child: VrxPress(onTap: () {}, child: const SizedBox(height: 60, child: Text('Pomodoro')))),
        SizedBox(
          width: 150,
          height: 150,
          child: Stack(children: [
            Positioned(left: 40, top: 40, width: 70, height: 70, child: VrxPress(onTap: () {}, child: const Text('20'))),
            Positioned(left: 0, top: 0, width: 60, height: 60, child: VrxPress(onTap: () {}, child: const Text('60'))),
          ]),
        ),
        // 5mm tall: under the touch minimum
        SizedBox(height: 32, width: 200, child: VrxPress(onTap: () {}, child: const SizedBox.expand())),
      ]),
    );
    expect(found, containsAll(['broken', 'target over target', 'text over text', 'small']));
  });

  testWidgets('controls too close, and one off the screen', (tester) async {
    final found = await rules(
      tester,
      (c) => Stack(children: [
        Positioned(left: 0, top: 0, width: 60, height: 60, child: VrxPress(onTap: () {}, child: const SizedBox())),
        // 0.5mm to the right of the first, not sharing its edge
        Positioned(left: 63, top: 10, width: 60, height: 60, child: VrxPress(onTap: () {}, child: const SizedBox())),
        Positioned(left: 250, top: 100, width: 60, height: 60, child: VrxPress(onTap: () {}, child: const SizedBox())),
      ]),
    );
    expect(found, containsAll(['gutter', 'off screen']));
  });
}
