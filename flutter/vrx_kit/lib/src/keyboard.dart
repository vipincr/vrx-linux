/// The on-screen keyboards. vrx boards have no system input method: the
/// kit's [VrxTextField] brings up the keyboard for what it holds (its
/// [VrxInputKind]) when it takes focus and the keyboard policy says so
/// ([VrxKeyboardPolicy]), and no screen places one. A terminal takes
/// keystrokes rather than text, so it shows [VrxKeyboard.terminal] itself.
///
/// One family per kind of value, every one the same height (four rows of
/// touch-minimum keys), so a screen laid out around one is laid out around
/// all of them:
///
/// - letters (text, password, search, email, url): the bottom row carries
///   what the kind wants to hand: @ and . for an email address, / . and
///   .com for an address (neither types a space), a search key, a go key;
/// - the number pad (number, decimal): four keys across, so a digit is a
///   quarter of the width and its face half the key's height;
/// - the phone pad (tel): the phone's 3 by 4 grid with its letters, + and -;
/// - wheels (date, time, datetime, month, week): the kit's wheels, writing
///   the HTML value as they turn;
/// - the gamepad: a D-pad and A, B, X, Y, Select and Start, sent to the
///   focused widget as key events (arrows and Flutter's game buttons, which
///   Flutter's own shortcuts already move focus and activate with).
///
/// Keys are the touch minimum tall (9mm). Across, ten letter keys share the
/// screen width: on a 43mm panel that is 4.3mm, under the 9mm floor. The
/// keyboard is the one sanctioned exception (AGENTS.md rule 10): a
/// smaller keyboard would need paging, and paging a passphrase loses
/// more taps than narrow keys do. The terminal keyboard is 6mm tall
/// (same rule): five rows at 9mm fill a 57mm panel and leave no output.
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'components.dart';
import 'metrics.dart';
import 'motion.dart';
import 'pickers.dart';
import 'scale.dart';
import 'symbols.dart';
import 'text_input.dart';
import 'theme.dart';
import 'ticker.dart';
import 'ui_standard.g.dart';

enum _Mode { lower, upper, symbols, more }

/// A key the terminal keyboard sends that is not text.
enum VrxTermKey { escape, tab, backspace, enter, left, up, down, right }

/// A gamepad button, and the key it sends: the D-pad the arrows (so focus
/// moves), A Flutter's game button A (which activates the focused control),
/// B game button B (which the kit takes as Back), the rest their game
/// buttons for the applet to bind.
enum VrxPadButton {
  up(LogicalKeyboardKey.arrowUp, PhysicalKeyboardKey.arrowUp),
  down(LogicalKeyboardKey.arrowDown, PhysicalKeyboardKey.arrowDown),
  left(LogicalKeyboardKey.arrowLeft, PhysicalKeyboardKey.arrowLeft),
  right(LogicalKeyboardKey.arrowRight, PhysicalKeyboardKey.arrowRight),
  a(LogicalKeyboardKey.gameButtonA, PhysicalKeyboardKey.gameButtonA),
  b(LogicalKeyboardKey.gameButtonB, PhysicalKeyboardKey.gameButtonB),
  x(LogicalKeyboardKey.gameButtonX, PhysicalKeyboardKey.gameButtonX),
  y(LogicalKeyboardKey.gameButtonY, PhysicalKeyboardKey.gameButtonY),
  select(LogicalKeyboardKey.gameButtonSelect, PhysicalKeyboardKey.gameButtonSelect),
  start(LogicalKeyboardKey.gameButtonStart, PhysicalKeyboardKey.gameButtonStart);

  const VrxPadButton(this.logical, this.physical);

  final LogicalKeyboardKey logical;
  final PhysicalKeyboardKey physical;

  /// The D-pad, which repeats while held.
  bool get repeats => index <= right.index;
}

/// The on-screen keyboard for [kind], typing into the field that brought
/// it up through [editor] (the gamepad takes none: it sends key events).
class VrxKeyboard extends StatefulWidget {
  const VrxKeyboard({super.key, this.kind = VrxInputKind.text, this.editor})
      : onText = null,
        onKey = null,
        onHide = null,
        onBack = null;

  /// Keystrokes for a terminal: [onText] gets typed text with Ctrl's
  /// state (Ctrl latches for one key), [onKey] the rest. A fifth row
  /// carries Back, Esc, Tab, Ctrl, the arrows and Hide.
  const VrxKeyboard.terminal({
    super.key,
    required void Function(String text, {bool ctrl}) this.onText,
    required void Function(VrxTermKey key) this.onKey,
    required VoidCallback this.onHide,
    required VoidCallback this.onBack,
  })  : kind = VrxInputKind.none,
        editor = null;

  final VrxInputKind kind;
  final VrxTextEditor? editor;
  final void Function(String text, {bool ctrl})? onText;
  final void Function(VrxTermKey key)? onKey;
  final VoidCallback? onHide;
  final VoidCallback? onBack;

  /// Every keyboard's height but the terminal's: four rows of
  /// touch-minimum keys 1mm apart, and a 1mm edge above and below.
  static double heightOf(BuildContext context) =>
      4 * (ScaledSpacing.of(context).touch + ScaledSpacing.of(context).xs) + 2 * ScaledSpacing.of(context).xs;

  /// Press [button] as a gamepad would: a key down (and, held, repeats)
  /// until [release]. The key data enters where the engine's does (the
  /// platform dispatcher's key data callback), so it reaches the focused
  /// widget, Flutter's shortcuts and HardwareKeyboard as a keyboard's does.
  static void press(VrxPadButton button) => _sendKey(button, ui.KeyEventType.down);

  static void release(VrxPadButton button) => _sendKey(button, ui.KeyEventType.up);

  static void _sendKey(VrxPadButton button, ui.KeyEventType type) {
    ServicesBinding.instance.platformDispatcher.onKeyData?.call(ui.KeyData(
      timeStamp: Duration(microseconds: DateTime.now().microsecondsSinceEpoch),
      type: type,
      physical: button.physical.usbHidUsage,
      logical: button.logical.keyId,
      character: null,
      synthesized: true,
    ));
  }

  @override
  State<VrxKeyboard> createState() => _VrxKeyboardState();
}

/// One key: the kit's press under a face sized to the key. [pop] shows the
/// face magnified above it while pressed (a character key, micro.key).
class _Key extends StatelessWidget {
  const _Key({
    required this.label,
    required this.onTap,
    required this.height,
    this.flex = 1,
    this.glyph,
    this.strong = false,
    this.pop = false,
    this.face = 0.38,
    this.sub,
  });

  final String label;
  final VoidCallback onTap;
  final double height;
  final int flex;
  final IconData? glyph;
  final bool strong;
  final bool pop;

  /// The face's size as a share of the key's height.
  final double face;

  /// A second, small line under the face (the phone pad's letters).
  final String? sub;

  @override
  Widget build(BuildContext context) {
    final colors = VrxTheme.of(context);
    final scale = VrxScale.of(context);
    TextStyle style(double share) =>
        TypeRole.of(context, VrxTypeRole.list).copyWith(fontSize: height * share, color: colors.text);
    final Widget text = sub == null
        ? Text(label, maxLines: 1, style: style(face))
        : Column(mainAxisSize: MainAxisSize.min, children: [
            Text(label, maxLines: 1, style: style(face)),
            Text(sub!, maxLines: 1, style: style(face * 0.4).copyWith(color: colors.textSecondary)),
          ]);
    return Expanded(
      flex: flex,
      child: Padding(
        // half the 1mm gutter each side: keys stand 1mm apart
        padding: EdgeInsets.all(Spacing.xs / 2 * scale),
        child: _KeyPop(
          height: height,
          enabled: pop && glyph == null,
          preview: Container(
            height: height,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: colors.surfaceHigh,
              border: Border.all(color: colors.outline, width: Strokes.hairline),
              borderRadius: BorderRadius.circular(Radii.sm * scale),
            ),
            child: Text(label, maxLines: 1, style: style(face)),
          ),
          child: VrxPress(
            onTap: onTap,
            label: label,
            child: Container(
              height: height,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: strong ? colors.secondaryContainer : colors.surfaceHigh,
                borderRadius: BorderRadius.circular(Radii.sm * scale),
              ),
              // a key is an instrument: its face is sized to the key, which
              // is sized from the scale; one line always, a narrow key
              // shrinks its word, never wraps it
              child: glyph != null ? Icon(glyph, size: height * 0.45) : FittedBox(fit: BoxFit.scaleDown, child: text),
            ),
          ),
        ),
      ),
    );
  }
}

class _VrxKeyboardState extends State<VrxKeyboard> {
  _Mode _mode = _Mode.lower;
  bool _ctrl = false;

  static const _letters = ['qwertyuiop', 'asdfghjkl', 'zxcvbnm'];
  static const _symbols = ['1234567890', r'@#$%&*-+()', r'!"' "'" r':;/?_.,'];
  // what a shell and a passphrase need that the first page lacks
  static const _more = [r'[]{}<>|\~^', '=`€£¥°•×÷', '§¶©®¿¡µ'];

  bool get _terminal => widget.onText != null;

  void _type(String text) {
    if (_terminal) {
      widget.onText!(text, ctrl: _ctrl);
      if (_ctrl) setState(() => _ctrl = false);
    } else {
      widget.editor?.type(text);
    }
    // one shifted letter, then back to lower case
    if (_mode == _Mode.upper) setState(() => _mode = _Mode.lower);
  }

  void _backspace() => _terminal ? widget.onKey!(VrxTermKey.backspace) : widget.editor?.backspace();

  void _enter() => _terminal ? widget.onKey!(VrxTermKey.enter) : widget.editor?.enter();

  @override
  Widget build(BuildContext context) {
    final colors = VrxTheme.of(context);
    final space = ScaledSpacing.of(context);
    final Widget keys = switch (widget.kind) {
      _ when _terminal => _letterKeys(context),
      VrxInputKind.number || VrxInputKind.decimal => _numberPad(context),
      VrxInputKind.tel => _phonePad(context),
      VrxInputKind.gamepad => const _Gamepad(),
      final k when k.wheels => _WheelKeys(kind: k, editor: widget.editor),
      _ => _letterKeys(context),
    };
    // The keys are part of the field they type into. On Linux (and every
    // desktop target) Flutter's text field drops its focus on a pointer down
    // outside it, touch included (EditableTextTapOutsideIntent's default
    // action); a tap on a key was such a tap, the field lost focus and took
    // its keyboard away (bench, 0.1.0122). Flutter's own text toolbars use this
    // region for the same reason.
    return TextFieldTapRegion(
      child: Container(
        color: colors.page,
        padding: EdgeInsets.symmetric(horizontal: space.xs / 2, vertical: space.xs),
        // the terminal's five short rows set their own height
        child: _terminal ? keys : SizedBox(height: VrxKeyboard.heightOf(context) - 2 * space.xs, child: keys),
      ),
    );
  }

  /// The letters, the symbol pages and the bottom row the kind wants.
  Widget _letterKeys(BuildContext context) {
    final rows = switch (_mode) {
      _Mode.symbols => _symbols,
      _Mode.more => _more,
      _ => _letters,
    };
    final upper = _mode == _Mode.upper;
    final letters = _mode == _Mode.lower || upper;
    final h = _terminal ? 6 * mmToDp * VrxScale.of(context) : ScaledSpacing.of(context).touch;
    Widget key(String label, VoidCallback onTap, {int flex = 1, IconData? glyph, bool strong = false}) =>
        _Key(label: label, onTap: onTap, height: h, flex: flex, glyph: glyph, strong: strong, pop: true);
    void term(VrxTermKey k) => widget.onKey!(k);
    final kind = widget.kind;
    final enter = key(
      switch (kind) {
        VrxInputKind.search => 'Search',
        VrxInputKind.url => 'Go',
        _ => 'Enter',
      },
      _enter,
      flex: 3,
      glyph: switch (kind) {
        VrxInputKind.search => VrxSymbols.search,
        VrxInputKind.url => VrxSymbols.arrow_forward,
        _ => VrxSymbols.keyboard_return,
      },
      strong: true,
    );
    final page = key(letters ? '123' : 'abc', () => setState(() => _mode = letters ? _Mode.symbols : _Mode.lower), flex: 3);
    // what each kind hands at the bottom; an address and an email address
    // never hold a space, so neither has the bar
    final bottom = switch (kind) {
      VrxInputKind.email => [page, key('@', () => _type('@'), flex: 4), key('.', () => _type('.'), flex: 3), key('_', () => _type('_'), flex: 2), enter],
      VrxInputKind.url => [page, key('/', () => _type('/'), flex: 2), key('.', () => _type('.'), flex: 2), key('.com', () => _type('.com'), flex: 4), enter],
      _ => [page, key('space', () => _type(' '), flex: 10), enter],
    };
    return _LayerFade(
      // letters (either case), symbols and the extra page are three layers
      layer: letters ? 0 : _mode.index,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_terminal)
            Row(children: [
              key('Back', widget.onBack!, glyph: VrxSymbols.arrow_back),
              key('esc', () => term(VrxTermKey.escape)),
              key('tab', () => term(VrxTermKey.tab)),
              key('ctrl', () => setState(() => _ctrl = !_ctrl), strong: _ctrl),
              key('Left', () => term(VrxTermKey.left), glyph: VrxSymbols.keyboard_arrow_left),
              key('Up', () => term(VrxTermKey.up), glyph: VrxSymbols.keyboard_arrow_up),
              key('Down', () => term(VrxTermKey.down), glyph: VrxSymbols.keyboard_arrow_down),
              key('Right', () => term(VrxTermKey.right), glyph: VrxSymbols.keyboard_arrow_right),
              key('Hide the keyboard', widget.onHide!, glyph: VrxSymbols.keyboard_hide),
            ]),
          for (var r = 0; r < rows.length; r++)
            Row(children: [
              if (r == 2)
                letters
                    ? key(upper ? 'Lower case' : 'Shift', () => setState(() => _mode = upper ? _Mode.lower : _Mode.upper),
                        flex: 3, glyph: upper ? VrxSymbols.keyboard_capslock : VrxSymbols.arrow_upward)
                    : key(_mode == _Mode.more ? '123' : '#+=',
                        () => setState(() => _mode = _mode == _Mode.more ? _Mode.symbols : _Mode.more),
                        flex: 3),
              for (final ch in rows[r].split(''))
                key(upper ? ch.toUpperCase() : ch, () => _type(upper ? ch.toUpperCase() : ch), flex: 2),
              if (r == 2) key('Delete', _backspace, flex: 3, glyph: VrxSymbols.backspace),
            ]),
          Row(children: _terminal ? [page, key('space', () => _type(' '), flex: 10), enter] : bottom),
        ],
      ),
    );
  }

  /// Four keys across, faces half the key's height: a digit is a quarter
  /// of the width, not a tenth. A whole number has no point.
  Widget _numberPad(BuildContext context) {
    final h = ScaledSpacing.of(context).touch;
    Widget key(String label, VoidCallback onTap, {int flex = 1, IconData? glyph, bool strong = false}) =>
        _Key(label: label, onTap: onTap, height: h, flex: flex, glyph: glyph, strong: strong, pop: true, face: 0.5);
    Widget digit(String d) => key(d, () => _type(d));
    final point = widget.kind == VrxInputKind.decimal;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Row(children: [digit('1'), digit('2'), digit('3'), key('Delete', _backspace, glyph: VrxSymbols.backspace)]),
      Row(children: [digit('4'), digit('5'), digit('6'), key('-', () => _type('-'))]),
      Row(children: [digit('7'), digit('8'), digit('9'), point ? key('.', () => _type('.')) : const Spacer()]),
      Row(children: [key('0', () => _type('0'), flex: 3), key('Done', _enter, glyph: VrxSymbols.check, strong: true)]),
    ]);
  }

  /// The phone's grid: digits with their letters, * and #, + and -.
  Widget _phonePad(BuildContext context) {
    final h = ScaledSpacing.of(context).touch;
    Widget key(String label, VoidCallback onTap, {String? sub, IconData? glyph, bool strong = false}) =>
        _Key(label: label, onTap: onTap, height: h, glyph: glyph, strong: strong, pop: true, face: 0.42, sub: sub);
    Widget digit(String d, [String? sub]) => key(d, () => _type(d), sub: sub);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Row(children: [digit('1'), digit('2', 'ABC'), digit('3', 'DEF'), key('Delete', _backspace, glyph: VrxSymbols.backspace)]),
      Row(children: [digit('4', 'GHI'), digit('5', 'JKL'), digit('6', 'MNO'), digit('+')]),
      Row(children: [digit('7', 'PQRS'), digit('8', 'TUV'), digit('9', 'WXYZ'), digit('-')]),
      Row(children: [digit('*'), digit('0'), digit('#'), key('Done', _enter, glyph: VrxSymbols.check, strong: true)]),
    ]);
  }
}

/// The wheels for a date, a time, both, a month or a week, writing the
/// HTML value (2026-10-15, 14:30, 2026-10-15T14:30, 2026-10, 2026-W42) into
/// the field as they turn, from what the field held (now, when it held
/// nothing readable; nothing is written until a wheel moves or Done).
class _WheelKeys extends StatefulWidget {
  const _WheelKeys({required this.kind, required this.editor});

  final VrxInputKind kind;
  final VrxTextEditor? editor;

  @override
  State<_WheelKeys> createState() => _WheelKeysState();
}

class _WheelKeysState extends State<_WheelKeys> {
  late final DateTime _start = _parse(widget.kind, widget.editor?.text ?? '') ?? DateTime.now();
  // the value, kept here as the wheels turn (a wheel off screen, the
  // datetime's other page, has no position to read)
  late DateTime _date = DateTime(_start.year, _start.month, _start.day);
  late int _mins = _start.hour * 60 + _start.minute;
  late (int, int) _week = _isoWeek(_start);
  // datetime shows the date's wheels or the time's
  bool _timePage = false;

  late _Turns _w = _Turns.at(_date, _mins, _week);

  @override
  void dispose() {
    _w.dispose();
    super.dispose();
  }

  /// The other page of a datetime: its wheels start where the value is.
  void _page(bool time) {
    final old = _w;
    setState(() {
      _w = _Turns.at(_date, _mins, _week);
      _timePage = time;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  /// The field's value, read back (null when it is not this kind's form).
  static DateTime? _parse(VrxInputKind kind, String s) {
    final m = switch (kind) {
      VrxInputKind.date => RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(s),
      VrxInputKind.time => RegExp(r'^(\d{2}):(\d{2})$').firstMatch(s),
      VrxInputKind.datetime => RegExp(r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})$').firstMatch(s),
      VrxInputKind.month => RegExp(r'^(\d{4})-(\d{2})$').firstMatch(s),
      VrxInputKind.week => RegExp(r'^(\d{4})-W(\d{2})$').firstMatch(s),
      _ => null,
    };
    if (m == null) return null;
    final n = [for (var i = 1; i <= m.groupCount; i++) int.parse(m.group(i)!)];
    return switch (kind) {
      VrxInputKind.date => DateTime(n[0], n[1], n[2]),
      VrxInputKind.time => DateTime(2000, 1, 1, n[0], n[1]),
      VrxInputKind.datetime => DateTime(n[0], n[1], n[2], n[3], n[4]),
      VrxInputKind.month => DateTime(n[0], n[1]),
      // the week's Thursday: the day that names an ISO week's year
      _ => DateTime(n[0], 1, 4).add(Duration(days: 7 * (n[1] - 1) - DateTime(n[0], 1, 4).weekday + 4)),
    };
  }

  /// The ISO week of [d]: (year, week), weeks starting Monday, week 1 the
  /// one holding the year's first Thursday.
  static (int, int) _isoWeek(DateTime d) {
    final thursday = DateTime(d.year, d.month, d.day + 4 - d.weekday);
    final week = (thursday.difference(DateTime(thursday.year, 1, 1)).inDays ~/ 7) + 1;
    return (thursday.year, week);
  }

  /// Weeks in an ISO year: 53 when it starts or (in a leap year) ends on a
  /// Thursday.
  static int _weeksIn(int year) => _isoWeek(DateTime(year, 12, 28)).$2;

  String _value() {
    final date = '${_date.year}-${_two(_date.month)}-${_two(_date.day)}';
    final time = '${_two(_mins ~/ 60)}:${_two(_mins % 60)}';
    return switch (widget.kind) {
      VrxInputKind.date => date,
      VrxInputKind.time => time,
      VrxInputKind.datetime => '${date}T$time',
      VrxInputKind.month => '${_date.year}-${_two(_date.month)}',
      _ => '${_week.$1}-W${_two(_week.$2)}',
    };
  }

  void _write() => widget.editor?.replace(_value());

  void _dateMoved() {
    _date = VrxDateWheels.read(_w.day, _w.month, _w.year);
    _write();
  }

  void _timeMoved() {
    _mins = VrxTimeWheels.read(_w.hours, _w.minutes);
    _write();
  }

  void _monthMoved() {
    _date = DateTime(VrxDateWheels.firstYear + _w.year.selectedItem % VrxDateWheels.years, _w.month.selectedItem % 12 + 1);
    _write();
  }

  void _weekMoved() {
    final y = VrxDateWheels.firstYear + _w.weekYear.selectedItem % VrxDateWheels.years;
    _week = (y, (_w.week.selectedItem % 53 + 1).clamp(1, _weeksIn(y)));
    _write();
  }

  @override
  Widget build(BuildContext context) {
    final h = ScaledSpacing.of(context).touch;
    final space = ScaledSpacing.of(context);
    Widget key(String label, VoidCallback onTap, {IconData? glyph, bool strong = false}) =>
        _Key(label: label, onTap: onTap, height: h, glyph: glyph, strong: strong);
    Widget wheel(FixedExtentScrollController c, int count, String Function(int) label, VoidCallback moved) =>
        Expanded(child: VrxWheel(controller: c, count: count, label: label, width: double.infinity, onChanged: (_) => moved()));
    String year(int i) => '${VrxDateWheels.firstYear + i}';
    final times = VrxTimeWheels(hours: _w.hours, minutes: _w.minutes, onChanged: _timeMoved);
    final Widget wheels = switch (widget.kind) {
      VrxInputKind.time => times,
      VrxInputKind.datetime when _timePage => times,
      VrxInputKind.month => Row(children: [
          wheel(_w.month, 12, (i) => VrxDateWheels.months[i], _monthMoved),
          SizedBox(width: space.md),
          wheel(_w.year, VrxDateWheels.years, year, _monthMoved),
        ]),
      VrxInputKind.week => Row(children: [
          wheel(_w.week, 53, (i) => 'W${_two(i + 1)}', _weekMoved),
          SizedBox(width: space.md),
          wheel(_w.weekYear, VrxDateWheels.years, year, _weekMoved),
        ]),
      _ => VrxDateWheels(day: _w.day, month: _w.month, year: _w.year, onChanged: _dateMoved),
    };
    return Column(children: [
      Expanded(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: space.inset),
          child: VrxWheelBand(children: [Expanded(child: wheels)]),
        ),
      ),
      Row(children: [
        if (widget.kind == VrxInputKind.datetime) ...[
          key('Date', () => _page(false), strong: !_timePage),
          key('Time', () => _page(true), strong: _timePage),
        ],
        key('Done', () {
          _write();
          widget.editor?.enter();
        }, glyph: VrxSymbols.check, strong: true),
      ]),
    ]);
  }
}

/// The wheels' controllers, at a value.
class _Turns {
  _Turns.at(DateTime date, int mins, (int, int) week)
      : day = FixedExtentScrollController(initialItem: date.day - 1),
        month = FixedExtentScrollController(initialItem: date.month - 1),
        year = FixedExtentScrollController(
            initialItem: (date.year - VrxDateWheels.firstYear).clamp(0, VrxDateWheels.years - 1)),
        hours = FixedExtentScrollController(initialItem: mins ~/ 60),
        minutes = FixedExtentScrollController(initialItem: mins % 60),
        week = FixedExtentScrollController(initialItem: week.$2 - 1),
        weekYear = FixedExtentScrollController(
            initialItem: (week.$1 - VrxDateWheels.firstYear).clamp(0, VrxDateWheels.years - 1));

  final FixedExtentScrollController day, month, year, hours, minutes, week, weekYear;

  void dispose() {
    for (final c in [day, month, year, hours, minutes, week, weekYear]) {
      c.dispose();
    }
  }
}

/// The gamepad: a D-pad on the left, A B X Y on the right as a controller
/// has them, Select and Start between. A press is a key down and a release
/// a key up ([VrxKeyboard.press]); the D-pad repeats while held, after
/// 400 ms, every 100 ms, as a held arrow key does.
class _Gamepad extends StatelessWidget {
  const _Gamepad();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      // three cells tall where the width allows: two 3-cell pads and Select
      // and Start between them (a cell and a half) across, so a narrow
      // panel shrinks the cell, not the buttons' order
      final cell = (box.maxHeight / 3).clamp(0.0, box.maxWidth / 7.5);
      Widget pad(Map<(int, int), (VrxPadButton, String, IconData?)> cells) => SizedBox(
            width: cell * 3,
            height: cell * 3,
            child: Stack(children: [
              for (final MapEntry(key: (col, row), value: (b, label, glyph)) in cells.entries)
                Positioned(
                  left: col * cell,
                  top: row * cell,
                  width: cell,
                  height: cell,
                  child: _PadButton(button: b, label: label, glyph: glyph, round: glyph == null),
                ),
            ]),
          );
      return Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        pad({
          (1, 0): (VrxPadButton.up, 'Up', VrxSymbols.keyboard_arrow_up),
          (0, 1): (VrxPadButton.left, 'Left', VrxSymbols.keyboard_arrow_left),
          (2, 1): (VrxPadButton.right, 'Right', VrxSymbols.keyboard_arrow_right),
          (1, 2): (VrxPadButton.down, 'Down', VrxSymbols.keyboard_arrow_down),
        }),
        Expanded(
          child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
            SizedBox(height: cell * 0.8, child: const _PadButton(button: VrxPadButton.select, label: 'Select')),
            SizedBox(height: cell * 0.8, child: const _PadButton(button: VrxPadButton.start, label: 'Start')),
          ]),
        ),
        pad({
          (1, 0): (VrxPadButton.y, 'Y', null),
          (0, 1): (VrxPadButton.x, 'X', null),
          (2, 1): (VrxPadButton.b, 'B', null),
          (1, 2): (VrxPadButton.a, 'A', null),
        }),
      ]);
    });
  }
}

/// One gamepad button: down on a finger's touch, up on its lift (or a
/// cancel), so a held button is a held key.
class _PadButton extends StatefulWidget {
  const _PadButton({required this.button, required this.label, this.glyph, this.round = false});

  final VrxPadButton button;
  final String label;
  final IconData? glyph;
  final bool round;

  @override
  State<_PadButton> createState() => _PadButtonState();
}

class _PadButtonState extends State<_PadButton> {
  bool _down = false;
  VrxTicker? _repeat;
  int _ticks = 0;

  void _press() {
    if (_down) return;
    setState(() => _down = true);
    VrxKeyboard.press(widget.button);
    if (!widget.button.repeats) return;
    _ticks = 0;
    // 100 ms ticks; the first four are the 400 ms before a key repeats
    _repeat = VrxTicker(const Duration(milliseconds: 100), () {
      if (++_ticks > 4) VrxKeyboard._sendKey(widget.button, ui.KeyEventType.repeat);
    });
  }

  void _release() {
    if (!_down) return;
    _repeat?.cancel();
    _repeat = null;
    setState(() => _down = false);
    VrxKeyboard.release(widget.button);
  }

  @override
  void dispose() {
    // a button torn down while held lets go of its key
    if (_down) {
      _repeat?.cancel();
      VrxKeyboard.release(widget.button);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = VrxTheme.of(context);
    final scale = VrxScale.of(context);
    return LayoutBuilder(builder: (context, box) {
      final side = box.biggest.shortestSide;
      return Semantics(
        button: true,
        label: widget.label,
        child: Listener(
          onPointerDown: (_) => _press(),
          onPointerUp: (_) => _release(),
          onPointerCancel: (_) => _release(),
          child: Padding(
            padding: EdgeInsets.all(Spacing.xs / 2 * scale),
            child: Container(
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: _down ? colors.secondaryContainer : colors.surfaceHigh,
                shape: widget.round ? BoxShape.circle : BoxShape.rectangle,
                borderRadius: widget.round ? null : BorderRadius.circular(Radii.sm * scale),
              ),
              child: widget.glyph != null
                  ? Icon(widget.glyph, size: side * 0.5)
                  : FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(widget.label,
                          maxLines: 1,
                          style: TypeRole.of(context, VrxTypeRole.list).copyWith(fontSize: side * 0.4, color: colors.text)),
                    ),
            ),
          ),
        ),
      );
    });
  }
}

/// A character key's preview (micro.key): a pressed key pops a magnified copy
/// of its face above it on the key row's spring, gone on lift. Paint only, so
/// no key moves; at light and below a scale of that size lands at once, so
/// there is no preview.
class _KeyPop extends StatefulWidget {
  const _KeyPop(
      {required this.height,
      required this.enabled,
      required this.preview,
      required this.child});

  final double height;
  final bool enabled;
  final Widget preview;
  final Widget child;

  @override
  State<_KeyPop> createState() => _KeyPopState();
}

class _KeyPopState extends State<_KeyPop> with SingleTickerProviderStateMixin {
  late final VrxSpringValue _p =
      VrxSpringValue(vsync: this, value: 0, unit: VrxUnit.fractionOf(40));
  bool _shows = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final mode = VrxMotion.of(context);
    _p.mode = mode;
    _shows = widget.enabled &&
        mode.allowsScale(vrxMicro[VrxMicro.key]!.scalePermille!);
  }

  void _to(double v) {
    if (_shows) _p.springTo(v, VrxSpring.micro(VrxMicro.key));
  }

  @override
  void dispose() {
    _p.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final big = vrxMicro[VrxMicro.key]!.scalePermille! / 1000;
    return Listener(
      onPointerDown: (_) => _to(1),
      onPointerUp: (_) => _to(0),
      onPointerCancel: (_) => _to(0),
      child: Stack(clipBehavior: Clip.none, children: [
        widget.child,
        if (_shows)
          Positioned(
            left: 0,
            right: 0,
            bottom: widget.height,
            child: ListenableBuilder(
              listenable: _p,
              builder: (context, child) => _p.value <= 0.001
                  ? const SizedBox.shrink()
                  : Transform.scale(
                      scale: 1 + (big - 1) * _p.value,
                      alignment: Alignment.bottomCenter,
                      child: child,
                    ),
              child: widget.preview,
            ),
          ),
      ]),
    );
  }
}

/// A layer change (letters, symbols, the extra page) fades the new layer in
/// on effects fast, at the full tier only (micro.key).
class _LayerFade extends StatefulWidget {
  const _LayerFade({required this.layer, required this.child});

  final int layer;
  final Widget child;

  @override
  State<_LayerFade> createState() => _LayerFadeState();
}

class _LayerFadeState extends State<_LayerFade>
    with SingleTickerProviderStateMixin {
  late final VrxSpringValue _p =
      VrxSpringValue(vsync: this, value: 1, unit: VrxUnit.alpha);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _p.mode = VrxMotion.of(context);
  }

  @override
  void didUpdateWidget(_LayerFade old) {
    super.didUpdateWidget(old);
    if (old.layer == widget.layer || !_p.mode.fades || !_p.mode.springs) return;
    _p.jumpTo(0);
    _p.springTo(1, VrxSpring.micro(VrxMicro.key, follow: true));
  }

  @override
  void dispose() {
    _p.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: _p,
        child: widget.child,
        builder: (context, child) =>
            Opacity(opacity: _p.value.clamp(0.0, 1.0), child: child),
      );
}
