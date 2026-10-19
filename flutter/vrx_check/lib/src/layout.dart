/// The layout rules, computed over a laid-out screen.
///
/// Every text run (RenderParagraph) and every tap target (a VrxPress,
/// InkWell, GestureDetector or text field that answers a tap) is reduced
/// to its rect on the display, in logical px (1 = 1/6.299 mm). The rules:
///
/// - overflow: a Flex that overflowed (Flutter's own report);
/// - framework: any other error Flutter raised during the layout pass,
///   filed by its kind (CON-08);
/// - cut: text truncated or dropped past its line limit, or taller than
///   the box it was given (a paragraph with no line limit is clipped at
///   its box's height: half a line shows, the rest is gone);
/// - broken: text wrapped inside a word ("Pomodor" / "o");
/// - text over text: two runs that overlap (a garbled stack);
/// - target over target: two controls whose hit areas overlap, so a tap
///   on one may land on the other;
/// - gutter: two controls closer than 1mm without sharing an edge (cells
///   of one list or grid share theirs, the hairline between them);
/// - small: a control under the 9mm touch minimum on a touch display
///   (VrxKeyboard's keys are sanctioned narrower, AGENTS.md rule 10);
/// - off screen: text or a control past the display's edge, outside any
///   scrolling list (which may hold more than fits); a scrollable's own
///   viewport may not leave the screen either (CON-04).
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

import 'displays.dart';
import 'fonts.dart';

/// One broken rule, where, and what it concerns.
class LayoutIssue {
  const LayoutIssue(this.rule, this.what, this.at);

  final String rule;
  final String what;
  final Rect at;

  @override
  String toString() =>
      '$rule: $what at (${at.left.toStringAsFixed(0)},${at.top.toStringAsFixed(0)} '
      '${at.width.toStringAsFixed(0)}x${at.height.toStringAsFixed(0)})';
}

/// Gaps and sizes in logical px.
const double _gutter = Spacing.xs; // 1mm
const double _touch = Spacing.touch; // 9mm
const double _eps = 0.5;

class _Target {
  _Target(this.element, this.rect, this.what, {required this.narrowOk, required this.shortOk, this.wheel});

  final Element element;
  final Rect rect;
  final String what;
  final bool narrowOk, shortOk;
  final Element? wheel;
}

/// Mount [applet] as the board shows it: below the shell's strip (the
/// shell's plane covers that much of every app), unless it is the shell.
Future<void> mountApplet<S, A, V>(WidgetTester tester, Applet<S, A, V> applet,
    {Stream<A>? actions, bool touch = true}) async {
  VrxShell.reset();
  addTearDown(VrxShell.reset);
  await tester.pumpWidget(AppletHost<S, A, V>(applet: applet, actions: actions, input: VrxInputFacts(touch: touch)));
  if (find.byType(VrxShellRegion).evaluate().isNotEmpty) return;
  final inside = find.byType(VrxInputRoot).evaluate().first;
  VrxShell.top.value = VrxStatusStrip.heightOf(inside) * tester.view.devicePixelRatio;
  await tester.pump();
}

/// Mount [applet] on [display] as runApplet would, let [setUp] act on it,
/// and return every rule it breaks. [setUp] may tap through the tester.
Future<List<LayoutIssue>> checkApplet<S, A, V>(
  WidgetTester tester,
  Applet<S, A, V> applet, {
  Display? display,
  Future<void> Function(WidgetTester tester)? setUp,
}) async {
  display ??= disp28a;
  await loadVrxFonts();
  final issues = <LayoutIssue>[];
  // G038 (plan 0014 D8): walks find controls by label, so every control
  // a person can tap says what it is; the semantics tree is built for the
  // check, as the walk driver turns it on to plan
  final semantics = tester.ensureSemantics();
  final previous = FlutterError.onError;
  // Flutter reports layout failures as errors; they are rules. Filed by
  // kind (CON-08, review 2026-10-17): a Flex overflow is the overflow
  // rule; anything else the framework raised (a paint error, an
  // assertion) is a framework issue naming its type, not an overflow it
  // is not.
  FlutterError.onError = (details) {
    final text = details.exceptionAsString();
    final first = text.split('\n').first;
    final kind = details.exception.runtimeType.toString();
    final isOverflow = first.contains('overflowed');
    issues.add(LayoutIssue(
      isOverflow ? 'overflow' : 'framework',
      isOverflow ? first : '[$kind] $first',
      Rect.zero,
    ));
  };
  try {
    tester.view.physicalSize = Size(display.width, display.height);
    tester.view.devicePixelRatio = display.pixelRatio;
    await mountApplet(tester, applet, touch: display.touch);
    await tester.pump(const Duration(milliseconds: 50));
    // plan 0017 D1: the applet is entering now; nothing under that motion may
    // sit behind an IgnorePointer or an AbsorbPointer
    issues.addAll(motionBlocksInput(tester));
    if (setUp != null) await setUp(tester);
    // the end state of every motion: layout is judged settled (G035 holds with
    // motion on), never half-way through a slide
    await settleMotion(tester);
    issues.addAll(motionBlocksInput(tester));
    issues.addAll(_inspect(tester, display));
    issues.addAll(unlabelledControls(tester));
    // G035 (plan 0013 D11): the same screen, the same state, under every
    // other display class: colours may differ, positions and sizes may
    // not. The host is pumped again with each class's colours; its store
    // and every route stay as they are.
    // the baseline is a re-pump too, with the colour class's own colours:
    // a rebuild may settle a screen (a list following its newest line),
    // and that is not the class's doing
    final input = VrxInputFacts(touch: display.touch);
    final classes = VrxColors.everyClass();
    await tester.pumpWidget(AppletHost<S, A, V>(applet: applet, colors: classes.first, input: input));
    await settleMotion(tester);
    final base = _geometry(tester);
    for (final colors in classes.skip(1)) {
      await tester.pumpWidget(AppletHost<S, A, V>(applet: applet, colors: colors, input: input));
      await settleMotion(tester);
      issues.addAll(_classIssues(base, _geometry(tester), colors.displayClass.name));
    }
    // plan 0013 D7: a touch panel's board may also have no touchscreen
    // fitted (the compositor says touch=0): the same screen without the
    // touch floor must still fit, though a dense control is no fault there
    if (display.touch) {
      await tester.pumpWidget(AppletHost<S, A, V>(applet: applet, input: const VrxInputFacts(touch: false)));
      await settleMotion(tester);
      final dense = Display(display.name, display.width, display.height, display.widthMm, touch: false, turns: display.turns);
      issues.addAll([
        for (final i in _inspect(tester, dense)) LayoutIssue(i.rule, 'without touch: ${i.what}', i.at),
      ]);
    }
  } finally {
    FlutterError.onError = previous;
    tester.view.reset();
    semantics.dispose();
  }
  return issues;
}

/// Pump until every motion has landed: a frame a second of simulated time, as
/// long as a frame is still wanted (a few rounds, so a spring started by the
/// last one lands too). The layout rules judge this end state (plan 0017 Part E).
Future<void> settleMotion(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(seconds: 1));
    if (!tester.binding.hasScheduledFrame) break;
  }
}

/// D1 (plan 0017): input lands mid-motion. A control is never behind an
/// `IgnorePointer` that ignores or an `AbsorbPointer` that absorbs, which is
/// how an animation that "locks until it ends" is written; a drawing over the
/// content that takes no input (a focus ring, a picture of a screen that has
/// left) holds no control and is fine. Call it while something moves.
List<LayoutIssue> motionBlocksInput(WidgetTester tester) {
  final issues = <LayoutIssue>[];
  bool blocks(Widget w) => (w is IgnorePointer && w.ignoring) || (w is AbsorbPointer && w.absorbing);
  for (final e in find.byWidgetPredicate(blocks).evaluate()) {
    final controls = find.descendant(of: find.byWidget(e.widget), matching: find.byWidgetPredicate(_answersTap));
    if (controls.evaluate().isEmpty) continue;
    final box = e.renderObject;
    issues.add(LayoutIssue(
      'motion blocks input',
      '${e.widget.runtimeType} sits over a control: input must land at every moment of a motion (plan 0017 D1)',
      box is RenderBox && box.hasSize ? _rectOf(box) : Rect.zero,
    ));
  }
  return issues;
}

/// G038 (plan 0014 D8): every control a person can tap (a semantics node
/// with the tap action, on screen and not hidden) has a label, value,
/// tooltip or hint: the words a walk finds it by, and what a screen reader
/// would say. The rect is in logical screen pixels.
List<LayoutIssue> unlabelledControls(WidgetTester tester) {
  SemanticsNode? root;
  void find(PipelineOwner owner) {
    root ??= owner.semanticsOwner?.rootSemanticsNode;
    owner.visitChildren(find);
  }

  find(tester.binding.rootPipelineOwner);
  if (root == null) return const [];
  final issues = <LayoutIssue>[];
  final dpr = tester.view.devicePixelRatio;
  void visit(SemanticsNode node, Matrix4 parent) {
    final transform = node.transform == null ? parent : (parent.clone()..multiply(node.transform!));
    final data = node.getSemanticsData();
    final words = '${data.label}${data.value}${data.tooltip}${data.hint}'.trim();
    final hidden = data.flagsCollection.isHidden || node.isInvisible;
    if (data.hasAction(SemanticsAction.tap) && words.isEmpty && !hidden) {
      final r = MatrixUtils.transformRect(transform, node.rect);
      issues.add(LayoutIssue('label', 'a control a person can tap has no label (G038)',
          Rect.fromLTRB(r.left / dpr, r.top / dpr, r.right / dpr, r.bottom / dpr)));
    }
    node.visitChildren((child) {
      visit(child, transform);
      return true;
    });
  }

  visit(root!, Matrix4.identity());
  return issues;
}

/// Mount [applet] on [display] as runApplet would and leave it mounted,
/// for a test's own measurements (proportions an applet promises).
Future<void> shotLayout<S, A, V>(WidgetTester tester, Applet<S, A, V> applet, {Display? display}) async {
  display ??= disp28a;
  await loadVrxFonts();
  tester.view.physicalSize = Size(display.width, display.height);
  tester.view.devicePixelRatio = display.pixelRatio;
  addTearDown(tester.view.reset);
  await mountApplet(tester, applet);
  await settleMotion(tester);
}

/// Run [checkApplet] and fail the test with every issue, one per line.
Future<void> expectCleanLayout<S, A, V>(
  WidgetTester tester,
  Applet<S, A, V> applet, {
  Display? display,
  Future<void> Function(WidgetTester tester)? setUp,
}) async {
  display ??= disp28a;
  final issues = await checkApplet(tester, applet, display: display, setUp: setUp);
  if (issues.isNotEmpty) {
    fail('${issues.length} layout issue(s) on ${display.name}:\n  ${issues.join('\n  ')}');
  }
}

/// D12 (plan 0013): mount [applet] on [display], let [change] act (a value
/// changes, a toggle flips, a fact arrives on [actions], the same stream
/// runApplet feeds), and return every tap target present before and after
/// whose size changed. A row grows with its own content up to its
/// ceiling; nothing under a finger resizes because the screen changed
/// around it.
Future<List<LayoutIssue>> checkStable<S, A, V>(
  WidgetTester tester,
  Applet<S, A, V> applet, {
  Display? display,
  Stream<A>? actions,
  required Future<void> Function(WidgetTester tester) change,
}) async {
  display ??= disp28a;
  await loadVrxFonts();
  tester.view.physicalSize = Size(display.width, display.height);
  tester.view.devicePixelRatio = display.pixelRatio;
  try {
    await mountApplet(tester, applet, actions: actions);
    await settleMotion(tester);
    final before = _targets(tester);
    await change(tester);
    await settleMotion(tester);
    final after = _targets(tester);
    final issues = <LayoutIssue>[];
    final seen = <String, int>{};
    for (final (what, rect) in before) {
      final n = seen[what] = (seen[what] ?? -1) + 1;
      final same = after.where((t) => t.$1 == what).toList();
      if (n >= same.length) continue; // gone: not a resize
      final now = same[n].$2;
      if ((now.width - rect.width).abs() > _eps || (now.height - rect.height).abs() > _eps) {
        issues.add(LayoutIssue(
          'resized',
          '$what was ${_size(rect)} and is ${_size(now)}: a control under a finger changed size',
          now,
        ));
      }
    }
    return issues;
  } finally {
    tester.view.reset();
  }
}

/// Run [checkStable] and fail the test with every issue, one per line.
Future<void> expectStable<S, A, V>(
  WidgetTester tester,
  Applet<S, A, V> applet, {
  Display? display,
  Stream<A>? actions,
  required Future<void> Function(WidgetTester tester) change,
}) async {
  display ??= disp28a;
  final issues = await checkStable(tester, applet, display: display, actions: actions, change: change);
  if (issues.isNotEmpty) {
    fail('${issues.length} control(s) resized on ${display.name}:\n  ${issues.join('\n  ')}');
  }
}

String _size(Rect r) => '${r.width.toStringAsFixed(0)}x${r.height.toStringAsFixed(0)}';

/// Every tap target on screen, in order, by what it says.
List<(String, Rect)> _targets(WidgetTester tester) => [
      for (final e in find.byWidgetPredicate(_answersTap).evaluate())
        if (e.renderObject case final RenderBox box when box.attached && box.hasSize && !_offstage(e)) (_describe(e), _rectOf(box)),
    ];

/// Where every text run and tap target sits, in order: what the class
/// sweep compares (plan 0013 D11).
List<(String, Rect)> _geometry(WidgetTester tester) => [
      for (final e in find.byWidgetPredicate((w) => w is RichText || _answersTap(w)).evaluate())
        if (e.renderObject case final RenderBox box when box.attached && box.hasSize && !_offstage(e))
          (e.widget is RichText ? '"${(e.widget as RichText).text.toPlainText()}"' : _describe(e), _rectOf(box)),
    ];

List<LayoutIssue> _classIssues(List<(String, Rect)> base, List<(String, Rect)> other, String cls) {
  if (base.length != other.length) {
    final only = [for (final b in base) if (!other.any((o) => o.$1 == b.$1)) b.$1];
    final extra = [for (final o in other) if (!base.any((b) => b.$1 == o.$1)) o.$1];
    return [
      LayoutIssue(
        'class',
        '${base.length} texts and targets under lcdColour, ${other.length} under $cls '
            '(only under lcdColour: ${only.join(', ')}; only under $cls: ${extra.join(', ')}): the layout depends on the display class',
        Rect.zero,
      ),
    ];
  }
  return [
    for (var i = 0; i < base.length; i++)
      if (!_same(base[i].$2, other[i].$2) || base[i].$1 != other[i].$1)
        LayoutIssue(
          'class',
          '${base[i].$1} sits at ${base[i].$2} under lcdColour and ${other[i].$1} at ${other[i].$2} under $cls: the layout depends on the display class',
          other[i].$2,
        ),
  ];
}

/// A box's rect on the display, through every transform above it (a
/// FittedBox's scale, a wheel's perspective).
Rect _rectOf(RenderBox box) => MatrixUtils.transformRect(box.getTransformTo(null), Offset.zero & box.size);

/// The part of [rect] a scrolling list shows: clipped to its viewport.
/// Null when the element is in no scrolling list.
Rect? _viewportOf(Element e) {
  Rect? clip;
  e.visitAncestorElements((a) {
    if (a.widget is Scrollable) {
      final box = a.renderObject;
      if (box is RenderBox && box.hasSize) clip = _rectOf(box);
      return false;
    }
    return true;
  });
  return clip;
}

/// The wheel an element turns with, if any: a wheel's rows are one
/// control, and overlap each other by design.
Element? _wheelOf(Element e) {
  Element? wheel;
  e.visitAncestorElements((a) {
    if (a.widget is ListWheelScrollView) {
      wheel = a;
      return false;
    }
    return true;
  });
  return wheel;
}

bool _under<T extends Widget>(Element e) {
  var found = false;
  e.visitAncestorElements((a) {
    if (a.widget is T) {
      found = true;
      return false;
    }
    return true;
  });
  return found;
}

/// Under an Offstage that is off stage. A ModalRoute wraps every page in
/// Offstage(offstage: false), so the widget's type alone says nothing.
bool _offstage(Element e) {
  var found = false;
  e.visitAncestorElements((a) {
    final w = a.widget;
    if (w is Offstage && w.offstage) {
      found = true;
      return false;
    }
    return true;
  });
  return found;
}

/// A scrim is a tap target under a panel, in a layer of its own: it is the
/// whole screen by design and is not a control the panel sits over.
bool _insideScrim(Element e) {
  var found = false;
  e.visitAncestorElements((a) {
    if (a.widget is VrxScrim) {
      found = true;
      return false;
    }
    return true;
  });
  return found;
}

bool _insideTextField(Element e) {
  var found = false;
  e.visitAncestorElements((a) {
    if (a.widget is TextField) {
      found = true;
      return false;
    }
    return true;
  });
  return found;
}

bool _isAncestor(Element maybeAncestor, Element of) {
  var found = false;
  of.visitAncestorElements((a) {
    if (identical(a, maybeAncestor)) {
      found = true;
      return false;
    }
    return true;
  });
  return found;
}

/// What a target says: the first text inside it, else its widget type.
String _describe(Element e) {
  String? text;
  void visit(Element c) {
    if (text != null) return;
    final w = c.widget;
    if (w is Text) {
      text = w.data ?? w.textSpan?.toPlainText();
    } else if (w is RichText) {
      text = w.text.toPlainText();
    } else if (w is Icon) {
      text = 'icon ${w.icon?.codePoint.toRadixString(16)}';
    }
    c.visitChildren(visit);
  }

  visit(e);
  return text == null ? e.widget.runtimeType.toString() : '"$text"';
}

bool _answersTap(Widget w) => switch (w) {
      VrxPress(:final onTap, :final onLongPress) => onTap != null || onLongPress != null,
      InkWell(:final onTap, :final onLongPress) => onTap != null || onLongPress != null,
      GestureDetector(:final onTap, :final onLongPress, :final onPanStart) =>
        onTap != null || onLongPress != null || onPanStart != null,
      TextField() => true,
      _ => false,
    };

List<LayoutIssue> _inspect(WidgetTester tester, Display display) {
  final issues = <LayoutIssue>[];
  final screen = Offset.zero & tester.view.physicalSize / tester.view.devicePixelRatio;

  // ── scrollables ─────────────────────────────────────────────────────
  // CON-04 (review 2026-10-17): a scrollable's CONTENT may hold more
  // than the screen; its viewport may not. Everything inside a scrollable
  // is exempt from the off-screen rule, so a list whose viewport itself
  // sat past the edge (a layout bug, not a long list) passed forever.
  for (final e in find.byType(Scrollable).evaluate()) {
    final box = e.renderObject;
    if (box is! RenderBox || !box.attached || !box.hasSize) continue;
    if (_offstage(e)) continue;
    final viewport = _rectOf(box);
    if (!_within(screen, viewport)) {
      issues.add(LayoutIssue('off screen', 'a scrollable\'s viewport', viewport));
    }
  }

  // ── modals ───────────────────────────────────────────────────────────
  // a modal's message is what a person must read: it may scroll only when
  // the client area (below the strip) could not hold it with one row of
  // acts under it (the bench, disp28a, 2026-10-14: "Every applet closes"
  // and the rest scrolled out of a dialog with room to spare)
  for (final e in find.byType(VrxModalMessage).evaluate()) {
    final scrollable = find.descendant(of: find.byWidget(e.widget), matching: find.byType(Scrollable));
    if (scrollable.evaluate().isEmpty) continue;
    final position = tester.state<ScrollableState>(scrollable.first).position;
    if (!position.hasContentDimensions || position.maxScrollExtent <= 0.5) continue;
    final s = ScaledSpacing.of(e);
    final client = screen.height - VrxShell.top.value / tester.view.devicePixelRatio;
    final content = position.viewportDimension + position.maxScrollExtent;
    // the fewest rows of acts the modal rule allows: Cancel and one act
    // share a row; two acts stack under Cancel
    final route = ModalRoute.of(e);
    final chips = route == null
        ? 2
        : find
            .byType(VrxChip)
            .evaluate()
            .where((c) => ModalRoute.of(c) == route)
            .length;
    final rows = chips <= 2 ? 1 : chips;
    final touch = ScaledSpacing.minInteractive(e);
    // the message, a gap, the acts, the dialog's padding and frame, the
    // inset above and below
    final needs = content + s.md + rows * touch + (rows - 1) * s.sm + 2 * s.md + 2 * Strokes.border + 2 * s.inset;
    if (needs <= client) {
      final box = e.renderObject;
      issues.add(LayoutIssue(
        'message scrolls',
        'a modal\'s message (${content.toStringAsFixed(0)} tall) scrolls though the client area (${client.toStringAsFixed(0)}) holds it',
        box is RenderBox && box.hasSize ? _rectOf(box) : Rect.zero,
      ));
    }
  }

  // ── text ─────────────────────────────────────────────────────────────
  final texts = <(RenderParagraph, Rect, String, bool)>[];
  for (final e in find.byType(RichText).evaluate()) {
    final box = e.renderObject;
    if (box is! RenderParagraph || !box.attached || !box.hasSize) continue;
    final text = box.text.toPlainText();
    if (text.trim().isEmpty) continue;
    // words squeezed to no room at all are the most cut text there is
    // (a Flex child given zero height); text Offstage is not on screen
    if (box.size.isEmpty) {
      if (!_offstage(e) && !_under<VrxTruncates>(e)) {
        issues.add(LayoutIssue('cut', '"$text" has no room (${box.size.width.toStringAsFixed(0)}x${box.size.height.toStringAsFixed(0)})', _rectOf(box)));
      }
      continue;
    }
    final whole = _rectOf(box);
    final viewport = _viewportOf(e);
    final scrolls = viewport != null;
    // what a scrolling list shows of it; nothing when scrolled out
    final rect = viewport == null ? whole : whole.intersect(viewport);
    if (rect.width <= 0 || rect.height <= 0) continue;
    texts.add((box, rect, text, scrolls));
    if (box.didExceedMaxLines && !_under<VrxTruncates>(e)) issues.add(LayoutIssue('cut', '"$text"', rect));
    // a line that ends inside a word: the paragraph's own text laid out
    // again at the width it had, its line ends read back
    final painter = TextPainter(
      text: box.text,
      textDirection: box.textDirection,
      textScaler: box.textScaler,
      maxLines: box.maxLines,
      textWidthBasis: box.textWidthBasis,
      textHeightBehavior: box.textHeightBehavior,
    )..layout(maxWidth: box.constraints.maxWidth.isFinite ? box.constraints.maxWidth : box.size.width);
    // taller than its box: clipped at the box's foot (no line limit
    // to exceed, so didExceedMaxLines never says so; bench, CM4,
    // 2026-10-14, the Assistant's empty state under a notice)
    if (!box.didExceedMaxLines && painter.height > box.size.height + 0.5 && !_under<VrxTruncates>(e)) {
      issues.add(LayoutIssue('cut', '"$text" is ${painter.height.toStringAsFixed(0)} tall in a ${box.size.height.toStringAsFixed(0)} box', rect));
    }
    var pos = 0;
    while (pos < text.length) {
      final end = painter.getLineBoundary(TextPosition(offset: pos)).end;
      if (end <= pos || end >= text.length) break;
      if (_isWordChar(text[end - 1]) && _isWordChar(text[end])) {
        issues.add(LayoutIssue('broken', '"$text" wraps inside a word', rect));
        break;
      }
      pos = end;
    }
    painter.dispose();
    if (!scrolls && !_within(screen, rect)) issues.add(LayoutIssue('off screen', '"$text"', rect));
  }
  for (var i = 0; i < texts.length; i++) {
    for (var j = i + 1; j < texts.length; j++) {
      final a = texts[i].$2, b = texts[j].$2;
      final o = a.intersect(b);
      // line boxes carry leading above and below the ink: a quarter of
      // the shorter run's height is where the glyphs meet
      final shorter = a.height < b.height ? a.height : b.height;
      if (o.width > 1 && o.height > shorter / 4) {
        issues.add(LayoutIssue('text over text', '"${texts[i].$3}" and "${texts[j].$3}"', o));
      }
    }
  }

  // ── targets ──────────────────────────────────────────────────────────
  final targets = <_Target>[];
  for (final e in find.byWidgetPredicate(_answersTap).evaluate()) {
    // a text field is one control, whatever detectors it builds inside
    if (_insideTextField(e) || _insideScrim(e)) continue;
    final box = e.renderObject;
    if (box is! RenderBox || !box.attached || !box.hasSize || box.size.isEmpty) continue;
    final whole = _rectOf(box);
    final viewport = _viewportOf(e);
    final rect = viewport == null ? whole : whole.intersect(viewport);
    if (rect.width <= 0 || rect.height <= 0) continue;
    // a control's own detector (VrxPress builds a GestureDetector, a
    // field its own) is the same control, not a second one
    if (targets.any((t) => _isAncestor(t.element, e) && (t.rect.deflate(_eps).overlaps(rect) && _same(t.rect, rect)))) {
      continue;
    }
    var keyboard = false;
    var terminalKeys = false;
    e.visitAncestorElements((a) {
      final w = a.widget;
      if (w is VrxKeyboard) {
        keyboard = true;
        terminalKeys = w.editor == null;
        return false;
      }
      return true;
    });
    final t = _Target(e, rect, _describe(e), narrowOk: keyboard, shortOk: terminalKeys, wheel: _wheelOf(e));
    targets.add(t);
    // a list shows part of a row at its edge: size is the whole row's
    if (display.touch) {
      final rect = whole;
      if (rect.height + _eps < _touch && !t.shortOk) {
        issues.add(LayoutIssue('small', '${t.what} is ${_mm(rect.height)}mm tall', rect));
      } else if (rect.width + _eps < _touch && !t.narrowOk) {
        issues.add(LayoutIssue('small', '${t.what} is ${_mm(rect.width)}mm wide', rect));
      }
    }
    if (viewport == null && !_within(screen, rect)) issues.add(LayoutIssue('off screen', t.what, rect));
  }
  for (var i = 0; i < targets.length; i++) {
    for (var j = i + 1; j < targets.length; j++) {
      final a = targets[i], b = targets[j];
      // a control inside another (a row's switch glyph) is its own part
      if (_isAncestor(a.element, b.element) || _isAncestor(b.element, a.element)) continue;
      if (a.wheel != null && identical(a.wheel, b.wheel)) continue;
      final o = a.rect.intersect(b.rect);
      if (o.width > _eps && o.height > _eps) {
        issues.add(LayoutIssue('target over target', '${a.what} and ${b.what}', o));
        continue;
      }
      final gap = _gap(a.rect, b.rect);
      if (gap < _gutter - _eps && !_shareEdge(a.rect, b.rect)) {
        issues.add(LayoutIssue('gutter', '${a.what} and ${b.what} are ${_mm(gap)}mm apart', a.rect.expandToInclude(b.rect)));
      }
    }
  }
  return issues;
}

bool _isWordChar(String c) => RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(c);

bool _within(Rect screen, Rect r) => screen.inflate(_eps).contains(r.topLeft) && screen.inflate(_eps).contains(r.bottomRight);

bool _same(Rect a, Rect b) =>
    (a.left - b.left).abs() < 1 && (a.top - b.top).abs() < 1 && (a.width - b.width).abs() < 1 && (a.height - b.height).abs() < 1;

/// The shortest distance between two rects that do not overlap.
double _gap(Rect a, Rect b) {
  final dx = [b.left - a.right, a.left - b.right, 0.0].reduce((x, y) => x > y ? x : y);
  final dy = [b.top - a.bottom, a.top - b.bottom, 0.0].reduce((x, y) => x > y ? x : y);
  return dx > dy ? dx : dy;
}

/// Cells of one column or row: abutting along one axis (a hairline
/// between them at most) with one's extent on the other axis inside the
/// other's (a list row under a header's back button, keys along a row).
bool _shareEdge(Rect a, Rect b) {
  bool inside(double a0, double a1, double b0, double b1) =>
      (a0 >= b0 - 1.5 && a1 <= b1 + 1.5) || (b0 >= a0 - 1.5 && b1 <= a1 + 1.5);
  final stacked = (b.top >= a.bottom - 1.5 || a.top >= b.bottom - 1.5) && inside(a.left, a.right, b.left, b.right);
  final abreast = (b.left >= a.right - 1.5 || a.left >= b.right - 1.5) && inside(a.top, a.bottom, b.top, b.bottom);
  return stacked || abreast;
}

String _mm(double logical) => (logical / mmToDp).toStringAsFixed(1);

/// For debugging a rule: every target and text the check saw.
@visibleForTesting
List<String> describeLayout(WidgetTester tester) => [
      for (final e in find.byWidgetPredicate(_answersTap).evaluate())
        if (e.renderObject is RenderBox) '${_describe(e)} ${_rectOf(e.renderObject! as RenderBox)}',
    ];
