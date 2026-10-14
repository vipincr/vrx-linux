import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/src/motion.dart';
import 'package:vrx_kit/src/ui_standard.g.dart';

/// The engine (plan 0017 D2, D3, D5): every spring in the kit is built here, with a tolerance in pixels, retargets
/// with its velocity, and is taken away by the still tier and by Reduce motion.
class _Probe extends StatefulWidget {
  const _Probe({this.mode = VrxMotionMode.full, required this.onValue});

  final VrxMotionMode mode;
  final void Function(VrxSpringValue value) onValue;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> with SingleTickerProviderStateMixin {
  late final VrxSpringValue v = VrxSpringValue(vsync: this, value: 0, unit: VrxUnit.px(), mode: widget.mode);

  @override
  void initState() {
    super.initState();
    widget.onValue(v);
  }

  @override
  void dispose() {
    v.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

const _drawer = VrxSpring(VrxSpringSet.standard, VrxSpringToken.spatialFast);

void main() {
  testWidgets('a retarget in flight keeps position and velocity', (tester) async {
    late VrxSpringValue v;
    await tester.pumpWidget(_Probe(onValue: (x) => v = x));
    v.springTo(300, _drawer);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final at = v.value, speed = v.velocity;
    expect(speed, greaterThan(500), reason: 'mid-flight');
    v.springTo(0, _drawer);
    // the new simulation starts where the old one was, going as fast
    expect(v.value, at);
    expect(v.velocity, closeTo(speed, speed * 0.01));
    await tester.pumpAndSettle();
    expect(v.value, 0, reason: 'snapToEnd: exactly on the target');
    expect(v.isAnimating, isFalse);
  });

  testWidgets('a spring lands exactly on its target and stops its ticker', (tester) async {
    late VrxSpringValue v;
    await tester.pumpWidget(_Probe(onValue: (x) => v = x));
    v.springTo(100, VrxSpring.micro(VrxMicro.drawerOpen));
    await tester.pumpAndSettle();
    expect(v.value, 100);
    expect(SchedulerBinding.instance.transientCallbackCount, 0);
  });

  testWidgets('at the still tier no controller ever has a ticker', (tester) async {
    late VrxSpringValue v;
    await tester.pumpWidget(_Probe(mode: const VrxMotionMode(VrxTier.still), onValue: (x) => v = x));
    v.springTo(300, VrxSpring.micro(VrxMicro.drawerOpen));
    expect(v.isAnimating, isFalse);
    expect(v.value, 300);
    expect(SchedulerBinding.instance.transientCallbackCount, 0);
  });

  testWidgets('taking springs away mid-flight lands the value on its target', (tester) async {
    late VrxSpringValue v;
    await tester.pumpWidget(_Probe(onValue: (x) => v = x));
    v.springTo(300, _drawer);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    expect(v.isAnimating, isTrue);
    v.mode = const VrxMotionMode(VrxTier.full, reduced: true);
    expect(v.isAnimating, isFalse);
    expect(v.value, 300);
  });

  test('the modes: what each tier and the Reduce motion row allow', () {
    const full = VrxMotionMode(VrxTier.full);
    const light = VrxMotionMode(VrxTier.light);
    const still = VrxMotionMode(VrxTier.still);
    const reduced = VrxMotionMode(VrxTier.full, reduced: true);
    expect([full.springs, light.springs, still.springs, reduced.springs], [true, true, false, false]);
    // a scale past the limit lands at once at light; a press's own sink is inside it
    expect([full.allowsScale(970), full.allowsScale(1300)], [true, true]);
    expect([light.allowsScale(970), light.allowsScale(1300), light.allowsScale(800)], [true, false, false]);
    expect([still.allowsScale(970), reduced.allowsScale(970)], [false, false]);
    // light slides without fading; full fades; a reduced build fades and does nothing else
    expect([full.fades, light.fades, still.fades, reduced.fades], [true, false, false, true]);
    expect([full.staggers, light.staggers, reduced.staggers], [true, false, false]);
  });

  test('Reduce motion only takes motion away: an e-paper class stays still whatever the row says', () {
    for (final cls in [VrxDisplayClass.epaperGrey, VrxDisplayClass.epaperMono]) {
      final tier = VrxMotion.tierFrom('', cls);
      expect(tier, VrxTier.still);
      for (final reduced in [false, true]) {
        final m = VrxMotionMode(tier, reduced: reduced);
        expect(m.springs, isFalse);
        expect(m.fadesOnly, isFalse, reason: 'still has nothing to fade');
      }
    }
    expect(VrxMotion.tierFrom('', VrxDisplayClass.lcdColour), VrxTier.full);
    expect(VrxMotion.tierFrom('', VrxDisplayClass.lcdGrey), VrxTier.light);
  });

  test('the build writes the tier and the kit reads it over the class', () {
    expect(VrxMotion.tierFrom('light\n', VrxDisplayClass.lcdColour), VrxTier.light);
    expect(VrxMotion.tierFrom('still', VrxDisplayClass.lcdColour), VrxTier.still);
    // absent, empty or garbled: the class's own
    expect(VrxMotion.tierFrom('', VrxDisplayClass.lcdGrey), VrxTier.light);
    expect(VrxMotion.tierFrom('warp', VrxDisplayClass.lcdColour), VrxTier.full);
  });

  testWidgets('Reduce motion on lands a spring builder at once, and a person can switch it on while it runs', (tester) async {
    Widget app({required bool reduce, required double value}) => MediaQuery(
          data: MediaQueryData(disableAnimations: reduce),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: VrxSpringBuilder(
              value: value,
              spring: _drawer,
              unit: VrxUnit.px(),
              builder: (context, v, _) => Text('${v.round()}'),
            ),
          ),
        );
    await tester.pumpWidget(app(reduce: false, value: 0));
    await tester.pumpWidget(app(reduce: false, value: 200));
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.text('200'), findsNothing, reason: 'moving');
    // the row is switched on mid-flight: it lands
    await tester.pumpWidget(app(reduce: true, value: 200));
    expect(find.text('200'), findsOneWidget);
    await tester.pumpWidget(app(reduce: true, value: 50));
    expect(find.text('50'), findsOneWidget);
  });

  testWidgets('a spring builder entering from [from] arrives and rests', (tester) async {
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: VrxSpringBuilder(
        value: 0,
        from: 24,
        spring: VrxSpring.micro(VrxMicro.applet),
        unit: VrxUnit.px(),
        builder: (context, v, _) => Text('${v.round()}'),
      ),
    ));
    expect(find.text('24'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('0'), findsOneWidget);
  });

  test('the tolerance is in pixels: spatial over the drawer travel is done at half a pixel, not at 1e-3 (D3)', () {
    const spring = VrxSpring(VrxSpringSet.standard, VrxSpringToken.spatial);
    final ours = vrxMeasure(spring, 360, VrxUnit.px());
    // Flutter's default tolerance keeps the same spring running about twice as long
    final theirs = SpringSimulation(spring.description, 0, 360, 0);
    var t = 0.0;
    while (!theirs.isDone(t)) {
      t += 0.001;
    }
    expect(ours.settleMs, inInclusiveRange(240, 300));
    expect(t * 1000, inInclusiveRange(500, 580));
    expect(ours.settleMs, lessThan(t * 1000 / 1.7));
    // and the simulation the engine builds carries the pixels, scaled by the display
    expect(vrxSimulate(spring, 0, 1, 0, VrxUnit.px()).tolerance.distance, 0.5);
    expect(vrxSimulate(spring, 0, 1, 0, VrxUnit.px(devicePixelRatio: 2)).tolerance.distance, 0.25);
    expect(vrxSimulate(spring, 0, 1, 0, VrxUnit.fractionOf(100)).tolerance.distance, 0.005);
    expect(vrxSimulate(spring, 0, 1, 0, VrxUnit.alpha).tolerance.distance, closeTo(1 / 255, 1e-4));
  });

  test('a bounce is the expressive set\'s, and a control that changes in place is crisp (D13)', () {
    // the generated table names each component's set, so a component cannot pick its own
    for (final row in [VrxMicro.press, VrxMicro.select, VrxMicro.handle, VrxMicro.key, VrxMicro.list, VrxMicro.banner]) {
      expect(vrxMicro[row]!.set, VrxSpringSet.standard, reason: '$row is in place');
    }
    for (final row in [VrxMicro.drawerOpen, VrxMicro.modal, VrxMicro.screen, VrxMicro.applet, VrxMicro.overscroll, VrxMicro.wheel]) {
      expect(vrxMicro[row]!.set, VrxSpringSet.expressive, reason: '$row travels');
    }
    // a closing overshoot would cross the strip
    expect(vrxMicro[VrxMicro.drawerClose]!.set, VrxSpringSet.standard);
    // overshoot: the expressive spatial fast passes its target, the standard's barely does
    double overshoot(VrxSpring s) {
      final sim = vrxSimulate(s, 0, 300, 0, VrxUnit.px());
      var peak = 0.0;
      for (var t = 0.0; t < 1; t += 0.001) {
        peak = peak > sim.x(t) ? peak : sim.x(t);
      }
      return (peak - 300) / 300;
    }

    expect(overshoot(VrxSpring.micro(VrxMicro.drawerOpen)), greaterThan(0.08));
    expect(overshoot(VrxSpring.micro(VrxMicro.drawerClose)), lessThan(0.005));
    expect(overshoot(VrxSpring.micro(VrxMicro.press)), lessThan(0.005));
  });

  test('effects springs are critically damped, so a colour or an opacity never overshoots', () {
    for (final set in VrxSpringSet.values) {
      for (final token in [VrxSpringToken.effects, VrxSpringToken.effectsFast, VrxSpringToken.effectsSlow]) {
        final s = VrxSpring(set, token);
        expect(s.isEffects, isTrue);
        final sim = vrxSimulate(s, 0, 1, 0, VrxUnit.alpha);
        for (var t = 0.0; t < 1; t += 0.002) {
          expect(sim.x(t), lessThanOrEqualTo(1.0 + 1e-9), reason: '${s.token} at $t');
        }
      }
    }
  });

  test('a route simulation lands at once at still and settles inside the ceiling otherwise', () {
    final landed = vrxRouteSimulation(
        mode: const VrxMotionMode(VrxTier.still),
        row: VrxMicro.modal,
        forward: true,
        from: 0,
        velocity: 0,
        travelPx: 40);
    expect([landed.isDone(0), landed.x(0)], [true, 0.85]);
    final run = vrxRouteSimulation(
        mode: VrxMotionMode.full, row: VrxMicro.modal, forward: true, from: 0, velocity: 0, travelPx: 40);
    expect(run.isDone(0), isFalse);
    expect(run.isDone(0.6), isTrue);
    // a pop goes back to 0
    final pop = vrxRouteSimulation(
        mode: VrxMotionMode.full, row: VrxMicro.modal, forward: false, from: 0.85, velocity: 0, travelPx: 40);
    expect(pop.x(5), 0);
  });

  test('the spring curve starts at 0, ends at 1 and runs about as long as the spring settles', () {
    final c = VrxSpringCurve(VrxSpring.micro(VrxMicro.wheel), 90);
    expect([c.transform(0), c.transform(1)], [0, 1]);
    expect(c.duration.inMilliseconds, inInclusiveRange(150, 600));
    var peak = 0.0;
    for (var t = 0.0; t <= 1; t += 0.01) {
      peak = peak > c.transform(t) ? peak : c.transform(t);
    }
    expect(peak, greaterThan(1.0), reason: 'the wheel bounces');
  });
}
