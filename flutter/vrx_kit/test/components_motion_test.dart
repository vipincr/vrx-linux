import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

/// plan 0017 Part C: each component's micro-interaction comes from the generated table and runs on the engine; input
/// lands mid-motion (D1); still and Reduce motion show the end state.
Widget host(Widget child, {VrxTier tier = VrxTier.full, bool reduce = false}) => MediaQuery(
      data: MediaQueryData(disableAnimations: reduce, size: const Size(480, 800)),
      child: VrxMotionScope(
        tier: tier,
        child: MaterialApp(
          scrollBehavior: const VrxScrollBehavior(),
          home: VrxFocusRing(child: Scaffold(body: child)),
        ),
      ),
    );

/// The scale of the nearest Transform above [finder] that scales.
double scaleOf(WidgetTester tester, Finder finder) {
  var scale = 1.0;
  for (final e in find.ancestor(of: finder, matching: find.byType(Transform)).evaluate()) {
    final m = (e.widget as Transform).transform;
    scale *= m.storage[0];
  }
  return scale;
}

void main() {
  group('press (micro.press)', () {
    Future<void> mount(WidgetTester tester, {VrxTier tier = VrxTier.full, bool reduce = false}) => tester.pumpWidget(
        host(Center(child: VrxPress(onTap: () {}, label: 'Go', child: const SizedBox(width: 200, height: 60, child: Text('Go')))),
            tier: tier, reduce: reduce));

    testWidgets('sinks to 0.97 on a finger and springs back on lift', (tester) async {
      await mount(tester);
      final g = await tester.startGesture(tester.getCenter(find.text('Go')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(scaleOf(tester, find.text('Go')), closeTo(0.97, 0.002));
      await g.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      final mid = scaleOf(tester, find.text('Go'));
      expect(mid, inExclusiveRange(0.97, 1.0), reason: 'on its way back');
      await tester.pumpAndSettle();
      expect(scaleOf(tester, find.text('Go')), 1.0);
    });

    testWidgets('at still, and with Reduce motion on, the inversion alone: no scale, no ticker', (tester) async {
      for (final (tier, reduce) in [(VrxTier.still, false), (VrxTier.full, true)]) {
        await mount(tester, tier: tier, reduce: reduce);
        final g = await tester.startGesture(tester.getCenter(find.text('Go')));
        await tester.pump();
        expect(scaleOf(tester, find.text('Go')), 1.0, reason: '$tier reduce=$reduce');
        expect(tester.binding.hasScheduledFrame, isFalse, reason: 'no spring is running');
        await g.up();
        await tester.pump();
      }
    });
  });

  group('segmented (micro.select)', () {
    Future<void> mount(WidgetTester tester, {VrxTier tier = VrxTier.full}) async {
      var selected = 0;
      await tester.pumpWidget(host(
        StatefulBuilder(
          builder: (context, set) => Center(
            child: SizedBox(
              width: 400,
              child: VrxSegmented(labels: const ['Day', 'Week', 'Month'], selected: selected, onSelected: (i) => set(() => selected = i)),
            ),
          ),
        ),
        tier: tier,
      ));
    }

    // the filled indicator is the one DecoratedBox with the primary colour
    double indicatorLeft(WidgetTester tester) {
      final box = find.byWidgetPredicate((w) => w is DecoratedBox && (w.decoration as BoxDecoration).color == VrxTheme.of(tester.element(find.byType(VrxSegmented))).primary);
      return tester.getTopLeft(box.first).dx;
    }

    testWidgets('the indicator slides to the new cell, and a tap mid-slide still lands', (tester) async {
      await mount(tester);
      final start = indicatorLeft(tester);
      await tester.tap(find.text('Month'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      final mid = indicatorLeft(tester);
      await tester.pumpAndSettle();
      final end = indicatorLeft(tester);
      expect(mid, greaterThan(start));
      expect(mid, lessThan(end), reason: 'half-way, not there yet');
      // a tap back at the mid of a second slide lands on the cell where it is drawn
      await tester.tap(find.text('Day'));
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tap(find.text('Week'));
      await tester.pumpAndSettle();
      final week = indicatorLeft(tester);
      expect(week, greaterThan(start));
      expect(week, lessThan(end));
    });

    testWidgets('at still the indicator is on the new cell in one paint', (tester) async {
      await mount(tester, tier: VrxTier.still);
      await tester.tap(find.text('Month'));
      await tester.pump();
      final at = indicatorLeft(tester);
      await tester.pumpAndSettle();
      expect(indicatorLeft(tester), at);
    });
  });

  group('banner (micro.banner)', () {
    Future<void> mount(WidgetTester tester, String? text, {VrxTier tier = VrxTier.full}) =>
        tester.pumpWidget(host(Align(alignment: Alignment.bottomCenter, child: VrxBanner(text: text)), tier: tier));

    testWidgets('slides in from its edge, and leaves on the quicker spring', (tester) async {
      await mount(tester, null);
      expect(find.text('Wi-Fi is off'), findsNothing);
      await mount(tester, 'Wi-Fi is off');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      final partial = tester.getSize(find.byType(VrxBanner)).height;
      await tester.pumpAndSettle();
      final whole = tester.getSize(find.byType(VrxBanner)).height;
      expect(partial, lessThan(whole), reason: 'still arriving');
      await mount(tester, null);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      expect(find.text('Wi-Fi is off'), findsOneWidget, reason: 'it leaves, it does not vanish');
      expect(tester.getSize(find.byType(VrxBanner)).height, lessThan(whole));
      await tester.pumpAndSettle();
      expect(find.text('Wi-Fi is off'), findsNothing);
    });

    testWidgets('at still it is there at once', (tester) async {
      await mount(tester, 'Wi-Fi is off', tier: VrxTier.still);
      final h = tester.getSize(find.byType(VrxBanner)).height;
      await tester.pump();
      expect(tester.getSize(find.byType(VrxBanner)).height, h);
      expect(h, greaterThan(0));
    });
  });

  group('list (micro.list)', () {
    Widget list({int rows = 12, void Function(int)? tapped}) => VrxList(children: [
          for (var i = 0; i < rows; i++) VrxRow(label: 'Row $i', onTap: () => tapped?.call(i)),
        ]);

    double opacityOf(WidgetTester tester, String text) {
      final o = find.ancestor(of: find.text(text), matching: find.byType(Opacity)).evaluate();
      return o.isEmpty ? 1.0 : (o.first.widget as Opacity).opacity;
    }

    testWidgets('the first eight enter in turn, the rest are there at once', (tester) async {
      await tester.pumpWidget(host(list()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      final first = opacityOf(tester, 'Row 0');
      final fourth = opacityOf(tester, 'Row 3');
      expect(first, greaterThan(fourth), reason: 'each waits 16 ms for the row above');
      expect(first, lessThan(1.0));
      await tester.pumpAndSettle();
      for (var i = 0; i < 8; i++) {
        expect(opacityOf(tester, 'Row $i'), 1.0);
      }
    });

    testWidgets('a tap at half-way lands on the row where it is drawn', (tester) async {
      final tapped = <int>[];
      await tester.pumpWidget(host(list(tapped: tapped.add)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tap(find.text('Row 1'));
      expect(tapped, [1]);
      await tester.pumpAndSettle();
    });

    testWidgets('at light and below the rows are there at once', (tester) async {
      for (final tier in [VrxTier.light, VrxTier.still]) {
        await tester.pumpWidget(host(list(), tier: tier));
        await tester.pump();
        expect(opacityOf(tester, 'Row 0'), 1.0, reason: '$tier');
        expect(opacityOf(tester, 'Row 5'), 1.0, reason: '$tier');
      }
    });

    testWidgets('a row scrolled out and back in does not enter again', (tester) async {
      await tester.pumpWidget(host(list(rows: 30)));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView), const Offset(0, -2000));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView), const Offset(0, 4000));
      await tester.pump();
      expect(opacityOf(tester, 'Row 0'), 1.0);
    });
  });

  group('slider (micro.handle)', () {
    double handle(WidgetTester tester) {
      final paint = tester.widget<CustomPaint>(find.descendant(of: find.byType(VrxSlider), matching: find.byType(CustomPaint)).first);
      // ignore: avoid_dynamic_calls
      return (paint.painter as dynamic).fraction as double;
    }

    Future<List<int>> mount(WidgetTester tester, int value) async {
      final rested = <int>[];
      var shown = value;
      await tester.pumpWidget(host(StatefulBuilder(
        builder: (context, set) => Center(
          child: SizedBox(
            width: 400,
            child: VrxSlider(label: 'Level', value: shown, onChangeEnd: (v) => set(() {
                  shown = v;
                  rested.add(v);
                })),
          ),
        ),
      )));
      return rested;
    }

    testWidgets('a step by key glides the handle; the value is the new one at once', (tester) async {
      await mount(tester, 50);
      expect(handle(tester), 0.5);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(handle(tester), inExclusiveRange(0.5, 0.6), reason: 'on its way to 60');
      expect(tester.getSemantics(find.byType(VrxSlider)).value, '60', reason: 'the readout does not ease');
      await tester.pumpAndSettle();
      expect(handle(tester), 0.6);
    });

    testWidgets('under a finger the handle is on the finger at every sample', (tester) async {
      await mount(tester, 50);
      final box = tester.getRect(find.byType(VrxSlider));
      final g = await tester.startGesture(Offset(box.left + box.width * 0.5, box.center.dy));
      await g.moveBy(const Offset(40, 0));
      await tester.pump();
      final a = handle(tester);
      await g.moveBy(const Offset(40, 0));
      await tester.pump();
      final b = handle(tester);
      expect(b, greaterThan(a));
      expect(tester.hasRunningAnimations, isFalse, reason: 'jumped, never trailing');
      await g.up();
      await tester.pumpAndSettle();
    });
  });

  group('wheel (micro.wheel)', () {
    testWidgets('a tap turns it on a spring and it ends on the row, bouncing is allowed past it', (tester) async {
      final c = FixedExtentScrollController(initialItem: 3);
      addTearDown(c.dispose);
      await tester.pumpWidget(host(Center(child: VrxWheel(controller: c, count: 24, label: (i) => '$i'))));
      await tester.tap(find.text('5').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(c.selectedItem, inInclusiveRange(3, 5));
      final mid = c.offset;
      await tester.pumpAndSettle();
      expect(c.selectedItem, 5);
      expect(mid, lessThan(c.offset), reason: 'was still travelling at 40 ms');
    });

    testWidgets('at still it lands at once', (tester) async {
      final c = FixedExtentScrollController(initialItem: 3);
      addTearDown(c.dispose);
      await tester.pumpWidget(host(Center(child: VrxWheel(controller: c, count: 24, label: (i) => '$i')), tier: VrxTier.still));
      await tester.tap(find.text('5').first);
      await tester.pump();
      expect(c.selectedItem, 5);
    });
  });

  group('keyboard (micro.key)', () {
    Future<void> mount(WidgetTester tester, {VrxTier tier = VrxTier.full}) async {
      final typed = <String>[];
      await tester.pumpWidget(host(
        Align(
          alignment: Alignment.bottomCenter,
          child: VrxKeyboard.terminal(onText: (t, {ctrl = false}) => typed.add(t), onKey: (_) {}, onHide: () {}, onBack: () {}),
        ),
        tier: tier,
      ));
    }

    testWidgets('a pressed character key pops a magnified preview, gone on lift', (tester) async {
      await mount(tester);
      final key = find.text('q');
      expect(key, findsOneWidget);
      final g = await tester.startGesture(tester.getCenter(key));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('q'), findsNWidgets(2), reason: 'the key and its preview');
      await g.up();
      await tester.pumpAndSettle();
      expect(find.text('q'), findsNWidgets(1), reason: 'gone on lift (hidden, kept as a shrunk box)');
    }, skip: false);

    testWidgets('light and still have no preview', (tester) async {
      for (final tier in [VrxTier.light, VrxTier.still]) {
        await mount(tester, tier: tier);
        final g = await tester.startGesture(tester.getCenter(find.text('q')));
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text('q'), findsOneWidget, reason: '$tier');
        await g.up();
        await tester.pumpAndSettle();
      }
    });

    testWidgets('a layer change fades the new layer in, at full', (tester) async {
      await mount(tester);
      await tester.tap(find.text('123'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 15));
      final o = find.ancestor(of: find.text('1'), matching: find.byType(Opacity)).evaluate().map((e) => (e.widget as Opacity).opacity);
      expect(o.any((v) => v < 1.0), isTrue);
      await tester.pumpAndSettle();
      expect(find.text('1'), findsOneWidget);
    });
  });

  group('modal (micro.modal)', () {
    Future<void> open(WidgetTester tester, {VrxTier tier = VrxTier.full, bool reduce = false, List<int?>? answers}) async {
      await tester.pumpWidget(host(Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () async {
              final answer = await vrxAsk(context, title: 'Delete?', message: 'It will go.', acts: ['Delete']);
              answers?.add(answer);
            },
            child: const Text('open'),
          ),
        ),
      ), tier: tier, reduce: reduce));
      await tester.tap(find.text('open'));
      await tester.pump();
      // the route's ticker takes its first frame as time zero
      await tester.pump(const Duration(milliseconds: 1));
    }

    testWidgets('grows from 800 permille on the expressive spring and settles at 1, scrim in step', (tester) async {
      await open(tester);
      await tester.pump(const Duration(milliseconds: 40));
      final grow = scaleOf(tester, find.text('Delete?'));
      expect(grow, inExclusiveRange(0.79, 0.999), reason: 'still growing at 40 ms');
      await tester.pump(const Duration(milliseconds: 90));
      // the expressive spring passes 1.0 on its way (a bounce) before it rests
      var peak = 0.0;
      for (var i = 0; i < 40; i++) {
        peak = peak > scaleOf(tester, find.text('Delete?')) ? peak : scaleOf(tester, find.text('Delete?'));
        await tester.pump(const Duration(milliseconds: 8));
      }
      expect(peak, greaterThan(1.0), reason: 'the dialog bounces');
      await tester.pumpAndSettle();
      expect(scaleOf(tester, find.text('Delete?')), closeTo(1.0, 1e-9));
    });

    testWidgets('a tap outside at half-way answers Cancel, and the modal leaves', (tester) async {
      final answers = <int?>[];
      await open(tester, answers: answers);
      await tester.pump(const Duration(milliseconds: 30));
      await tester.tapAt(const Offset(2, 2));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      expect(answers, [null]);
      await tester.pumpAndSettle();
      expect(find.text('Delete?'), findsNothing);
    });

    testWidgets('at still and with Reduce motion on, it is there at once at full size', (tester) async {
      for (final (tier, reduce) in [(VrxTier.still, false), (VrxTier.full, true)]) {
        await open(tester, tier: tier, reduce: reduce);
        await tester.pump(const Duration(milliseconds: 1));
        expect(scaleOf(tester, find.text('Delete?')), 1.0, reason: '$tier $reduce');
        await tester.tapAt(const Offset(2, 2));
        await tester.pumpAndSettle();
      }
    });
  });

  group('focus ring (micro.focus)', () {
    testWidgets('one ring moves between controls, on the spring', (tester) async {
      await tester.pumpWidget(host(Column(children: [
        VrxPress(onTap: () {}, label: 'one', child: const SizedBox(height: 60, width: 300, child: Text('one'))),
        const SizedBox(height: 100),
        VrxPress(onTap: () {}, label: 'two', child: const SizedBox(height: 60, width: 300, child: Text('two'))),
      ])));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.pump();
      final ring = find.byWidgetPredicate((w) => w is CustomPaint && w.painter.runtimeType.toString() == '_RingPainter');
      expect(ring, findsOneWidget);
      Rect at() => ((tester.widget<CustomPaint>(ring).painter as dynamic).rect() as Rect);
      final first = at();
      expect(first.top, tester.getTopLeft(find.text('one')).dy);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      final mid = at();
      expect(mid.top, greaterThan(first.top));
      await tester.pumpAndSettle();
      expect(at().top, closeTo(tester.getTopLeft(find.text('two')).dy, 0.6));
    });
  });

  group('scrolling (D10)', () {
    Widget scroller() => ListView(children: [for (var i = 0; i < 30; i++) SizedBox(height: 60, child: Text('item $i'))]);

    testWidgets('a drag past the top travels with friction and springs back', (tester) async {
      await tester.pumpWidget(host(scroller()));
      final list = find.byType(ListView);
      final g = await tester.startGesture(tester.getCenter(list));
      for (var i = 0; i < 12; i++) {
        await g.moveBy(const Offset(0, 10));
        await tester.pump(const Duration(milliseconds: 8));
      }
      final position = tester.state<ScrollableState>(find.byType(Scrollable)).position;
      expect(position.pixels, lessThan(0), reason: 'past the end');
      expect(position.pixels, greaterThan(-120), reason: 'with friction');
      await g.up();
      await tester.pumpAndSettle();
      expect(position.pixels, 0);
    });

    testWidgets('at still and with Reduce motion on a list stops dead at its end', (tester) async {
      for (final (tier, reduce) in [(VrxTier.still, false), (VrxTier.full, true)]) {
        await tester.pumpWidget(host(scroller(), tier: tier, reduce: reduce));
        final g = await tester.startGesture(tester.getCenter(find.byType(ListView)));
        await g.moveBy(const Offset(0, 120));
        await tester.pump();
        expect(tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels, 0, reason: '$tier $reduce');
        await g.up();
      }
    });

    testWidgets('a mouse wheel scrolls at the speed it always did', (tester) async {
      await tester.pumpWidget(host(scroller()));
      final position = tester.state<ScrollableState>(find.byType(Scrollable)).position;
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(pointer.hover(tester.getCenter(find.byType(ListView))));
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 100)));
      await tester.pumpAndSettle();
      expect(position.pixels, 100);
    });

    testWidgets('a page snap and a wheel detent take the one physics as their parent', (tester) async {
      await tester.pumpWidget(host(VrxPaged(builder: (context, box) => SizedBox(height: box.maxHeight * 2, child: const Text('tall')))));
      final physics = tester.state<ScrollableState>(find.byType(Scrollable)).position.physics;
      expect(physics, isA<PageScrollPhysics>());
      expect(physics.parent, isA<VrxScrollPhysics>());
    });
  });
}
