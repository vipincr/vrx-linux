import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

/// plan 0017 Part E: a screen change slides in (D6) and an applet enters (D8), on the engine, with input live
/// the whole way and the end state at once where nothing may move.
class _Screens extends StatefulWidget {
  const _Screens({super.key, this.tier = VrxTier.full, this.reduce = false, this.taps});

  final VrxTier tier;
  final bool reduce;
  final List<String>? taps;

  @override
  State<_Screens> createState() => _ScreensState();
}

class _ScreensState extends State<_Screens> {
  Object screen = 'a';
  int depth = 0;

  void go(Object s, int d) => setState(() {
        screen = s;
        depth = d;
      });

  @override
  Widget build(BuildContext context) => MediaQuery(
        data: MediaQueryData(disableAnimations: widget.reduce),
        child: VrxMotionScope(
          tier: widget.tier,
          child: MaterialApp(
            home: Scaffold(
              body: VrxSwitch(
                screen: screen,
                depth: depth,
                child: Center(
                  child: VrxPress(
                    key: ValueKey(screen),
                    onTap: () => widget.taps?.add('$screen'),
                    label: 'screen $screen',
                    child: SizedBox(width: 200, height: 60, child: Text('screen $screen')),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
}

double xOf(WidgetTester tester, String text) => tester.getCenter(find.text(text)).dx;

double opacityOf(WidgetTester tester, String text) {
  var o = 1.0;
  for (final e in find.ancestor(of: find.text(text), matching: find.byType(Opacity)).evaluate()) {
    o *= (e.widget as Opacity).opacity;
  }
  return o;
}

void main() {
  Future<_ScreensState> mount(WidgetTester tester, {VrxTier tier = VrxTier.full, bool reduce = false, List<String>? taps}) async {
    tester.view.physicalSize = const Size(480, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_Screens(key: UniqueKey(), tier: tier, reduce: reduce, taps: taps));
    await tester.pumpAndSettle();
    return tester.state<_ScreensState>(find.byType(_Screens));
  }

  Future<void> begin(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 30));
  }

  testWidgets('a deeper screen comes from the right and settles in place', (tester) async {
    final s = await mount(tester);
    final rest = xOf(tester, 'screen a');
    s.go('b', 1);
    await begin(tester);
    expect(xOf(tester, 'screen b'), greaterThan(rest), reason: 'still on its way in from the right');
    expect(opacityOf(tester, 'screen b'), lessThan(1.0), reason: 'full fades it in');
    await tester.pumpAndSettle();
    expect(xOf(tester, 'screen b'), closeTo(rest, 0.01));
    expect(opacityOf(tester, 'screen b'), 1.0);
  });

  testWidgets('Back comes from the left, an equal depth cross-fades in place', (tester) async {
    final s = await mount(tester);
    final rest = xOf(tester, 'screen a');
    s.go('b', 1);
    await tester.pumpAndSettle();
    s.go('a', 0);
    await begin(tester);
    expect(xOf(tester, 'screen a'), lessThan(rest), reason: 'from the left');
    await tester.pumpAndSettle();
    s.go('c', 0);
    await begin(tester);
    expect(xOf(tester, 'screen c'), closeTo(rest, 0.01), reason: 'equal depth does not slide');
    expect(opacityOf(tester, 'screen c'), lessThan(1.0));
    await tester.pumpAndSettle();
  });

  testWidgets('a tap at half-way lands on the control where it is drawn, and a second change retargets', (tester) async {
    final taps = <String>[];
    final s = await mount(tester, taps: taps);
    s.go('b', 1);
    await begin(tester);
    await tester.tapAt(tester.getCenter(find.text('screen b')));
    expect(taps, ['b']);
    // another change before this one has landed: one animation, from where it is
    s.go('c', 2);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.hasRunningAnimations, isTrue);
    await tester.pumpAndSettle();
    expect(find.text('screen c'), findsOneWidget);
  });

  testWidgets('light slides without fading; still is one paint; Reduce motion only fades', (tester) async {
    var s = await mount(tester, tier: VrxTier.light);
    final rest = xOf(tester, 'screen a');
    s.go('b', 1);
    await begin(tester);
    expect(xOf(tester, 'screen b'), greaterThan(rest));
    expect(opacityOf(tester, 'screen b'), 1.0, reason: 'light does not fade');
    await tester.pumpAndSettle();

    s = await mount(tester, tier: VrxTier.still);
    s.go('b', 1);
    await tester.pump();
    expect(xOf(tester, 'screen b'), rest);
    expect(opacityOf(tester, 'screen b'), 1.0);
    expect(tester.hasRunningAnimations, isFalse);

    s = await mount(tester, reduce: true);
    s.go('b', 1);
    await begin(tester);
    expect(xOf(tester, 'screen b'), closeTo(rest, 0.01), reason: 'no travel with Reduce motion on');
    expect(opacityOf(tester, 'screen b'), lessThan(1.0), reason: 'a quick fade at most');
    await tester.pumpAndSettle();
  });

  group('an applet enters (D8)', () {
    Future<void> app(WidgetTester tester, {VrxTier tier = VrxTier.full, bool reduce = false}) => tester.pumpWidget(MediaQuery(
          data: MediaQueryData(disableAnimations: reduce),
          child: VrxMotionScope(
            tier: tier,
            child: MaterialApp(home: VrxEntrance(key: UniqueKey(), child: const Scaffold(body: Align(alignment: Alignment.topLeft, child: Text('content'))))),
          ),
        ));

    testWidgets('the content rises and fades in over the page colour; a cold start counts', (tester) async {
      await app(tester);
      expect(opacityOf(tester, 'content'), 0.0, reason: 'the first paint is the page colour alone');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      final y = tester.getTopLeft(find.text('content')).dy;
      expect(opacityOf(tester, 'content'), inExclusiveRange(0.0, 1.0));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text('content')).dy, lessThan(y), reason: 'it rose into place');
      expect(opacityOf(tester, 'content'), 1.0);
    });

    testWidgets('coming back from behind another enters again, once, and never stacks', (tester) async {
      await app(tester);
      await tester.pumpAndSettle();
      for (final s in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      expect(opacityOf(tester, 'content'), lessThan(1.0));
      // resumed again while it runs: a retarget, still one animation
      for (final s in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pumpAndSettle();
      expect(opacityOf(tester, 'content'), 1.0);
    });

    testWidgets('a flick to inactive and back (a system sheet) is not an entrance', (tester) async {
      await app(tester);
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(opacityOf(tester, 'content'), 1.0);
    });

    testWidgets('still is there at once; light slides; Reduce motion fades without rising', (tester) async {
      await app(tester, tier: VrxTier.still);
      expect(opacityOf(tester, 'content'), 1.0);
      expect(tester.hasRunningAnimations, isFalse);
      await app(tester, tier: VrxTier.light);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      expect(opacityOf(tester, 'content'), 1.0, reason: 'light does not fade');
      await tester.pumpAndSettle();
      final rest = tester.getTopLeft(find.text('content')).dy;
      await app(tester, reduce: true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      expect(tester.getTopLeft(find.text('content')).dy, closeTo(rest, 0.01));
      expect(opacityOf(tester, 'content'), lessThan(1.0));
      await tester.pumpAndSettle();
    });
  });

  test('the harness refuses a screen whose Back goes deeper', () {
    final model = _Deepening();
    final h = StoreHarness<int, String, int>(model);
    h.dispatch('open');
    expect(
      () => h.verify(fresh: _Deepening.new, probes: const ['open']),
      throwsA(isA<StateError>().having((e) => e.toString(), 'message', contains('goes deeper'))),
    );
  });
}

/// A model with one screen over its root whose Back, wrongly, raises its depth.
class _Deepening extends StoreModel<int, String, int> {
  int level = 0;

  @override
  int get initial => 0;

  @override
  String get bootAction => 'boot';

  @override
  int reduce(int state, String action) {
    if (action == 'open') level = 1;
    if (action == 'back') level = 2;
    return level;
  }

  @override
  int get snapshot => level;

  @override
  String get backAction => 'back';

  @override
  bool get atRoot => level == 0 || level == 3;

  @override
  int get depth => level;

  @override
  void restore(int snapshot) => level = snapshot;
}
