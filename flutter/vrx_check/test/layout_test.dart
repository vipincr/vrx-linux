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
  testWidgets('G038: a control with no words fails, the same control labelled passes', (tester) async {
    final bare = await rules(
      tester,
      (c) => Center(child: GestureDetector(onTap: () {}, child: const SizedBox(width: 80, height: 80))),
    );
    expect(bare, contains('label'));
    final labelled = await rules(
      tester,
      (c) => Center(
        child: Semantics(
          label: 'Start the timer',
          child: GestureDetector(onTap: () {}, child: const SizedBox(width: 80, height: 80)),
        ),
      ),
    );
    expect(labelled, isNot(contains('label')));
  });

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

  // the kit's slider, as Settings and the drawer lay it: a status row and
  // the slider under it at the inset, at the ends and in the middle
  for (final display in allDisplays) {
    testWidgets('a slider row is clean on ${display.name}', (tester) async {
      final found = [
        for (final i in await checkApplet(
            tester,
            _Screen((c) => VrxList(children: [
                  const VrxHeader(title: 'Display', onBack: null),
                  for (final v in const [0, 55, 100]) ...[
                    VrxRow(label: 'Brightness', value: '$v'),
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: ScaledSpacing.of(c).inset),
                      child: VrxSlider(label: 'Brightness', value: v, onChangeEnd: (_) {}),
                    ),
                  ],
                ])),
            display: display))
          '$i',
      ];
      expect(found, isEmpty);
    });
  }

  // G035 (plan 0013 D11): a screen that sizes itself by the display class
  // is caught; the kit's own screens are not
  testWidgets('a layout that depends on the display class is caught (G035)', (tester) async {
    final found = await rules(
      tester,
      (c) => VrxList(children: [
        // a branch on the class: more room on a colour panel
        // vrx-allow: the fixture breaks G035 on purpose
        SizedBox(height: VrxTheme.of(c).displayClass.name == 'lcdColour' ? 40 : 60),
        VrxRow(label: 'Repeat', value: 'Weekdays', onTap: () {}),
      ]),
    );
    expect(found, contains('class'));
  });

  // D12 (plan 0013): a row whose value changes under a finger keeps its
  // size when it knows its widest value; without it, it jumps
  testWidgets('a row that changes size under a finger is caught, and widestValue holds it (D12)', (tester) async {
    Future<List<String>> flip({String? widest}) async {
      final long = ValueNotifier(false);
      final applet = _Screen((c) => ValueListenableBuilder<bool>(
            valueListenable: long,
            builder: (c, on, _) => VrxList(children: [
              VrxRow(
                label: 'Keep the screen on',
                value: on ? 'Always, while plugged in' : 'Off',
                widestValue: widest,
                onTap: () => long.value = !long.value,
              ),
            ]),
          ));
      final issues = await checkStable(tester, applet, change: (t) async => long.value = true);
      return [for (final i in issues) i.rule];
    }

    expect(await flip(), contains('resized'));
    expect(await flip(widest: 'Always, while plugged in'), isEmpty);
  });

  test('a turned display is the same panel on its side, at the same density (D10)', () {
    final t = disp28a.turned;
    expect((t.width, t.height), (disp28a.height, disp28a.width));
    expect(t.pixelRatio, closeTo(disp28a.pixelRatio, 1e-9));
    // vrx_check itself has no manifest: no applet here turns
    expect(allDisplays.where((d) => d.name.endsWith('turned')), isEmpty);
  });
}
