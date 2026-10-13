/// The layout rules, computed over a laid-out screen.
///
/// Every text run (RenderParagraph) and every tap target (a VrxPress,
/// InkWell, GestureDetector or text field that answers a tap) is reduced
/// to its rect on the display, in logical px (1 = 1/6.299 mm). The rules:
///
/// - overflow: a Flex that overflowed (Flutter's own report);
/// - cut: text truncated or dropped past its line limit;
/// - broken: text wrapped inside a word ("Pomodor" / "o");
/// - text over text: two runs that overlap (a garbled stack);
/// - target over target: two controls whose hit areas overlap, so a tap
///   on one may land on the other;
/// - gutter: two controls closer than 1mm without sharing an edge (cells
///   of one list or grid share theirs, the hairline between them);
/// - small: a control under the 9mm touch minimum on a touch display
///   (VrxKeyboard's keys are sanctioned narrower, AGENTS.md rule 10);
/// - off screen: text or a control past the display's edge, outside any
///   scrolling list (which may hold more than fits).
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

/// Mount [applet] on [display] as runApplet would, let [setUp] act on it,
/// and return every rule it breaks. [setUp] may tap through the tester.
Future<List<LayoutIssue>> checkApplet<S, A, V>(
  WidgetTester tester,
  Applet<S, A, V> applet, {
  Display display = disp28a,
  Future<void> Function(WidgetTester tester)? setUp,
}) async {
  await loadVrxFonts();
  final issues = <LayoutIssue>[];
  final previous = FlutterError.onError;
  // Flutter reports a Flex overflow as an error; it is one of the rules
  FlutterError.onError = (details) {
    final text = details.exceptionAsString();
    issues.add(LayoutIssue('overflow', text.split('\n').first, Rect.zero));
  };
  try {
    tester.view.physicalSize = Size(display.width, display.height);
    tester.view.devicePixelRatio = display.pixelRatio;
    await tester.pumpWidget(AppletHost<S, A, V>(applet: applet));
    await tester.pump(const Duration(milliseconds: 50));
    if (setUp != null) await setUp(tester);
    await tester.pump(const Duration(seconds: 1));
    issues.addAll(_inspect(tester, display));
  } finally {
    FlutterError.onError = previous;
    tester.view.reset();
  }
  return issues;
}

/// Mount [applet] on [display] as runApplet would and leave it mounted,
/// for a test's own measurements (proportions an applet promises).
Future<void> shotLayout<S, A, V>(WidgetTester tester, Applet<S, A, V> applet, {Display display = disp28a}) async {
  await loadVrxFonts();
  tester.view.physicalSize = Size(display.width, display.height);
  tester.view.devicePixelRatio = display.pixelRatio;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(AppletHost<S, A, V>(applet: applet));
  await tester.pump(const Duration(seconds: 1));
}

/// Run [checkApplet] and fail the test with every issue, one per line.
Future<void> expectCleanLayout<S, A, V>(
  WidgetTester tester,
  Applet<S, A, V> applet, {
  Display display = disp28a,
  Future<void> Function(WidgetTester tester)? setUp,
}) async {
  final issues = await checkApplet(tester, applet, display: display, setUp: setUp);
  if (issues.isNotEmpty) {
    fail('${issues.length} layout issue(s) on ${display.name}:\n  ${issues.join('\n  ')}');
  }
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

  // ── text ─────────────────────────────────────────────────────────────
  final texts = <(RenderParagraph, Rect, String, bool)>[];
  for (final e in find.byType(RichText).evaluate()) {
    final box = e.renderObject;
    if (box is! RenderParagraph || !box.attached || !box.hasSize || box.size.isEmpty) continue;
    final text = box.text.toPlainText();
    if (text.trim().isEmpty) continue;
    final whole = _rectOf(box);
    final viewport = _viewportOf(e);
    final scrolls = viewport != null;
    // what a scrolling list shows of it; nothing when scrolled out
    final rect = viewport == null ? whole : whole.intersect(viewport);
    if (rect.width <= 0 || rect.height <= 0) continue;
    texts.add((box, rect, text, scrolls));
    if (box.didExceedMaxLines) issues.add(LayoutIssue('cut', '"$text"', rect));
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
    if (_insideTextField(e)) continue;
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
        terminalKeys = w.controller == null;
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
