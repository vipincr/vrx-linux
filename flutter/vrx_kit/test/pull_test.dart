import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

/// The drawer's mechanics (plan 0017 D7, was the strip's swipe): it follows
/// the finger 1:1, flings onto a spring with the finger's velocity, rubber-bands
/// past its end, stops under a second finger, reverses with its momentum when
/// the model closes it, and says when it is engaged so the shell's region is the
/// whole screen from the first moved pixel to the last settled one.
const _strip = 40.0;
const _panel = 200.0;
const _panelKey = Key('panel');

class _Harness extends StatefulWidget {
  const _Harness({required this.log, required this.engaged, this.open = false, this.back, this.tier = VrxTier.full});

  final List<bool> log;
  final List<bool> engaged;
  final bool open;
  final VoidCallback? back;
  final VrxTier tier;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  late bool open = widget.open;

  @override
  Widget build(BuildContext context) => VrxMotionScope(
        tier: widget.tier,
        child: MaterialApp(
          home: Scaffold(
            body: VrxPull(
              open: open,
              top: _strip,
              onIntent: (v) {
                widget.log.add(v);
                setState(() => open = v);
              },
              strip: (context, pull) {
                widget.engaged.add(pull.engaged);
                return pull.handle(SizedBox(
                  height: _strip,
                  width: double.infinity,
                  child: Row(children: [
                    VrxPress(
                      onTap: widget.back,
                      label: 'Back',
                      child: const SizedBox(width: 60, height: _strip, child: Text('Back')),
                    ),
                  ]),
                ));
              },
              panel: const SizedBox(key: _panelKey, height: _panel, width: double.infinity, child: Text('panel')),
            ),
          ),
        ),
      );

  void set(bool v) => setState(() => open = v);
}

double panelTop(WidgetTester tester) => tester.getTopLeft(find.byKey(_panelKey)).dy;

void main() {
  late List<bool> log, engaged;
  setUp(() {
    log = [];
    engaged = [];
  });

  Future<void> mount(WidgetTester tester, {bool open = false, VrxTier tier = VrxTier.full, VoidCallback? back}) async {
    tester.view.physicalSize = const Size(480, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_Harness(log: log, engaged: engaged, open: open, tier: tier, back: back));
  }

  testWidgets('it follows the finger 1:1, to the pixel, at every sample', (tester) async {
    await mount(tester);
    expect(find.byKey(_panelKey), findsNothing, reason: 'closed: nothing of the drawer is mounted');
    final g = await tester.startGesture(const Offset(300, 20));
    // the layer mounts at the first moved pixel and measures the panel a frame later
    await g.moveTo(const Offset(300, 40));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    for (final dy in [30.0, 61.0, 94.0, 130.0, 180.0]) {
      await g.moveTo(Offset(300, 20 + dy));
      await tester.pump(const Duration(milliseconds: 16));
      // the panel's lower edge is dy below where it started (under the strip's lower edge)
      expect(panelTop(tester) + _panel, closeTo(_strip + dy, 1.0), reason: 'finger at +$dy');
    }
    await g.up();
    await tester.pumpAndSettle();
  });

  testWidgets('a fling down opens it and says so once; a fling up closes it', (tester) async {
    await mount(tester);
    await tester.fling(find.text('Back'), const Offset(0, 60), 900);
    await tester.pumpAndSettle();
    expect(log, [true]);
    expect(panelTop(tester), _strip, reason: 'open, at rest, exactly under the strip');
    await tester.fling(find.byKey(_panelKey), const Offset(0, -60), 900);
    await tester.pumpAndSettle();
    expect(log, [true, false]);
    expect(find.byKey(_panelKey), findsNothing, reason: 'closed and settled: unmounted again');
  });

  testWidgets('a release above the velocity opens it even from a tenth of the way; a slow one decides by the middle', (tester) async {
    await mount(tester);
    // 11 % of the way in two quick samples: fast enough to open
    final quick = await tester.startGesture(const Offset(300, 20));
    await quick.moveBy(const Offset(0, 11), timeStamp: const Duration(milliseconds: 8));
    await quick.moveBy(const Offset(0, 11), timeStamp: const Duration(milliseconds: 16));
    await quick.up();
    await tester.pumpAndSettle();
    expect(log, [true], reason: '22 px is 11 % of the panel');
    // slow, back to 90 % of the way, then let go with no speed: it is past the middle
    await tester.fling(find.byKey(_panelKey), const Offset(0, -60), 900);
    await tester.pumpAndSettle();
    log.clear();
    final g = await tester.startGesture(const Offset(300, 20));
    for (var i = 1; i <= 10; i++) {
      await g.moveTo(Offset(300, 20 + 18.0 * i));
      await tester.pump(const Duration(milliseconds: 120));
    }
    await tester.pump(const Duration(milliseconds: 300));
    await g.up();
    await tester.pumpAndSettle();
    expect(log, [true], reason: '90 % and still: it opens');
    // from open, drag up slowly to 40 % and let go still: it closes
    final up = await tester.startGesture(const Offset(300, _strip + 100));
    for (var i = 1; i <= 6; i++) {
      await up.moveTo(Offset(300, _strip + 100 - 20.0 * i));
      await tester.pump(const Duration(milliseconds: 120));
    }
    await tester.pump(const Duration(milliseconds: 300));
    await up.up();
    await tester.pumpAndSettle();
    expect(log, [true, false], reason: 'only past the middle does it stay: this was 40 %');
  });

  testWidgets('a slow release short of the middle goes back and says nothing', (tester) async {
    await mount(tester);
    final g = await tester.startGesture(const Offset(300, 20));
    for (var i = 1; i <= 5; i++) {
      await g.moveTo(Offset(300, 20 + 14.0 * i));
      await tester.pump(const Duration(milliseconds: 120));
    }
    await tester.pump(const Duration(milliseconds: 300));
    await g.up();
    await tester.pumpAndSettle();
    expect(log, isEmpty);
    expect(find.byKey(_panelKey), findsNothing);
  });

  testWidgets('past its end the rubber band never passes the skirt', (tester) async {
    await mount(tester);
    final g = await tester.startGesture(const Offset(300, 20));
    var worst = 0.0;
    for (var i = 1; i <= 30; i++) {
      await g.moveTo(Offset(300, 20 + 20.0 * i));
      await tester.pump(const Duration(milliseconds: 16));
      worst = worst > panelTop(tester) ? worst : panelTop(tester);
    }
    expect(worst, greaterThan(_strip), reason: 'it travels past its stop');
    expect(worst, lessThanOrEqualTo(_strip + VrxPull.skirt + 0.01), reason: 'by 40 px at the most');
    await g.up();
    await tester.pumpAndSettle();
    expect(panelTop(tester), _strip, reason: 'and springs back to its stop');
  });

  testWidgets('a second finger on a moving drawer stops it where it is and takes over', (tester) async {
    await mount(tester);
    await tester.fling(find.text('Back'), const Offset(0, 60), 900);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    final g = await tester.startGesture(const Offset(300, 120));
    final at = panelTop(tester);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pump(const Duration(milliseconds: 60));
    expect(panelTop(tester), at, reason: 'held under the finger');
    // and the finger moves it
    await g.moveBy(const Offset(0, -40));
    await tester.pump(const Duration(milliseconds: 16));
    expect(panelTop(tester), lessThan(at));
    await g.up();
    await tester.pumpAndSettle();
  });

  testWidgets('the model closing an open drawer mid-open reverses it with its momentum', (tester) async {
    await mount(tester);
    await tester.fling(find.text('Back'), const Offset(0, 60), 900);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    await tester.pump(const Duration(milliseconds: 30));
    final before = panelTop(tester);
    tester.state<_HarnessState>(find.byType(_Harness)).set(false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    final next = panelTop(tester);
    expect((next - before).abs(), lessThan(30), reason: 'no jump: it carries on from where it was, with its speed');
    await tester.pumpAndSettle();
    expect(find.byKey(_panelKey), findsNothing);
  });

  testWidgets('engaged is true from the first moved pixel to the settled close', (tester) async {
    await mount(tester);
    expect(engaged.last, isFalse);
    final g = await tester.startGesture(const Offset(300, 20));
    await g.moveBy(const Offset(0, 20), timeStamp: const Duration(milliseconds: 8));
    await g.moveBy(const Offset(0, 20), timeStamp: const Duration(milliseconds: 16));
    await tester.pump();
    expect(engaged.last, isTrue, reason: 'a finger has it');
    await g.up();
    await tester.pumpAndSettle();
    expect(engaged.last, isTrue, reason: 'open: the whole screen is the shell\'s');
    await tester.fling(find.byKey(_panelKey), const Offset(0, -60), 900);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    expect(engaged.last, isTrue, reason: 'closing: still on screen');
    await tester.pumpAndSettle();
    expect(engaged.last, isFalse, reason: 'closed and settled');
    expect(engaged.where((e) => e).length, greaterThan(2));
  });

  testWidgets('a restored open drawer mounts open, with no animation', (tester) async {
    await mount(tester, open: true);
    expect(panelTop(tester), _strip);
    expect(tester.hasRunningAnimations, isFalse);
    expect(log, isEmpty, reason: 'a restore is not a person\'s act');
    expect(engaged.last, isTrue);
  });

  testWidgets('a tap on the scrim closes it and the scrim says so in words', (tester) async {
    final semantics = tester.ensureSemantics();
    await mount(tester, open: true);
    await tester.pump();
    expect(find.bySemanticsLabel(RegExp('Close the drawer')), findsOneWidget);
    await tester.tapAt(const Offset(240, _strip + _panel + 60));
    await tester.pumpAndSettle();
    expect(log, [false]);
    expect(find.byKey(_panelKey), findsNothing);
    semantics.dispose();
  });

  testWidgets('the panel eats a tap; a tap on Back reaches Back and never opens the drawer', (tester) async {
    var back = 0;
    await mount(tester, open: true, back: () => back++);
    await tester.tap(find.text('panel'));
    await tester.pumpAndSettle();
    expect(log, isEmpty, reason: 'the panel does not dismiss');
    await tester.tap(find.text('Back'));
    expect(back, 1);
    await tester.fling(find.byKey(_panelKey), const Offset(0, -60), 900);
    await tester.pumpAndSettle();
    log.clear();
    await tester.tap(find.text('Back'));
    await tester.pump();
    expect(back, 2);
    expect(log, isEmpty, reason: 'a tap is Back, never the drawer');
    // a nudge under the slop does nothing, and a sideways swipe is not this
    await tester.drag(find.text('Back'), const Offset(0, 5));
    await tester.pump();
    await tester.fling(find.text('Back'), const Offset(80, 10), 800);
    await tester.pumpAndSettle();
    expect(log, isEmpty);
  });

  testWidgets('a mouse drag from the strip pulls it as a finger does', (tester) async {
    await mount(tester);
    final g = await tester.startGesture(const Offset(300, 20), kind: PointerDeviceKind.mouse);
    await g.moveBy(const Offset(0, 100));
    await tester.pump();
    await tester.pump();
    expect(panelTop(tester) + _panel, closeTo(_strip + 100, 1.0));
    await g.up();
    await tester.pumpAndSettle();
  });

  testWidgets('at the still tier it opens in one paint, and a bounce is never shown', (tester) async {
    await mount(tester, tier: VrxTier.still);
    await tester.fling(find.text('Back'), const Offset(0, 60), 900);
    await tester.pump();
    expect(log, [true]);
    expect(panelTop(tester), _strip);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });
}
