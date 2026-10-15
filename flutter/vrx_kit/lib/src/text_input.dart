/// The on-screen keyboard belongs to the field typed into (owner,
/// 2026-10-15). vrx boards have no system input method, so the kit's
/// [VrxTextField] brings its own: focused, it hands the applet root's
/// [VrxKeyboardSlot] the keyboard for its [VrxInputKind], typing into its
/// own controller, and takes it back when focus leaves. The root only gives
/// the keyboard its place under the screen; no screen and no applet places
/// one, except through the exceptional [VrxKeyboardSlot.show].
///
/// A field says what it holds, as an HTML input's type does, and the kind
/// picks the keys: letters for text, letters with @ and . to hand for an
/// email address, / and .com for an address, a phone pad, a number pad with
/// large keys, wheels for a date or a time, a gamepad. The kind also filters
/// what either keyboard may type.
///
/// Whether a focused field shows its keyboard is one decision for every
/// field, [VrxKeyboardPolicy]: never while a physical keyboard is plugged in
/// (the compositor's [VrxInputFacts.keyboard]), unless Settings > Device says
/// Show ([VrxKeyboardMode.show]). A physical keyboard types through the
/// platform's text input, as on any Flutter target.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'keyboard.dart';
import 'screen.dart';

/// What a field holds, which picks its keyboard and filters what it takes
/// (HTML's input types, the ones that type).
enum VrxInputKind {
  /// Free text (HTML `text`; `textarea` when the field has several lines).
  text,

  /// A secret: dots, not letters (HTML `password`).
  password,

  /// A query: Enter searches (HTML `search`).
  search,

  /// A web address: no space, with / . and .com to hand (HTML `url`).
  url,

  /// An email address: no space, with @ and . to hand (HTML `email`).
  email,

  /// A phone number: the phone pad, digits and + * # ( ) - (HTML `tel`).
  tel,

  /// A whole number, signed: the number pad (HTML `number`, numeric mode).
  number,

  /// A number with a decimal point: the number pad with a point (HTML
  /// `number` with a fractional step, decimal mode).
  decimal,

  /// A date, held as 2026-10-15: day, month and year wheels (HTML `date`).
  date,

  /// A time of day, held as 14:30: hour and minute wheels (HTML `time`).
  time,

  /// A date and a time, held as 2026-10-15T14:30: the date wheels and the
  /// time wheels, one set at a time (HTML `datetime-local`).
  datetime,

  /// A month, held as 2026-10: month and year wheels (HTML `month`).
  month,

  /// An ISO week, held as 2026-W42: week and year wheels (HTML `week`).
  week,

  /// A gamepad: a D-pad and A, B, X, Y, Select and Start, sent to the
  /// focused widget as key events (arrows and Flutter's game buttons); on a
  /// field, A submits it.
  gamepad,

  /// The field brings its own keys (the Scripts editor's terminal keys) and
  /// takes no keyboard from the kit.
  none;

  /// The wheels, rather than keys.
  bool get wheels => index >= date.index && index <= week.index;

  /// Flutter's name for it, for the platform's text input.
  TextInputType get textInputType => switch (this) {
        text || password => TextInputType.text,
        search => TextInputType.text,
        url => TextInputType.url,
        email => TextInputType.emailAddress,
        tel => TextInputType.phone,
        number => const TextInputType.numberWithOptions(signed: true),
        decimal => const TextInputType.numberWithOptions(signed: true, decimal: true),
        date || time || datetime || month || week => TextInputType.datetime,
        gamepad || none => TextInputType.none,
      };

  /// What it may hold, typed on either keyboard; null takes anything.
  RegExp? get allowed => switch (this) {
        url || email => RegExp(r'\S'),
        tel => RegExp(r'[0-9+*#()\- ]'),
        number => RegExp(r'[0-9\-]'),
        decimal => RegExp(r'[0-9.\-]'),
        date || time || datetime || month || week => RegExp(r'[0-9\-:TW]'),
        _ => null,
      };
}

/// The one decision: does a focused field show the on-screen keyboard?
abstract final class VrxKeyboardPolicy {
  /// Show it unless a physical keyboard is plugged in; Settings' Show
  /// shows it anyway.
  static bool shows({required VrxKeyboardMode mode, required bool physicalKeyboard}) =>
      mode == VrxKeyboardMode.show || !physicalKeyboard;

  /// The decision where [context] is: false outside an applet root (a
  /// widget test with no [VrxKeyboardSlot] gets no keyboard).
  static bool of(BuildContext context) => _SlotScope.maybeOf(context)?.shows ?? false;
}

/// What the on-screen keyboard types into.
abstract interface class VrxTextEditor {
  /// Enter types a newline here, rather than ending the entry.
  bool get multiline;

  /// The text held now (the wheels start from it).
  String get text;

  /// Type [text] over the selection.
  void type(String text);

  /// Replace the whole text (the wheels set a value at once).
  void replace(String text);

  /// Delete the selection, or the character before the caret.
  void backspace();

  /// Enter: a newline in a multi-line field, else the field's submit.
  void enter();
}

/// The keyboard's place under the screen (AppletHost installs it below
/// the strip). It reads the facts the policy needs and draws the keyboard
/// a focused field hands it; it decides nothing itself.
class VrxKeyboardSlot extends StatefulWidget {
  const VrxKeyboardSlot({super.key, required this.child, this.settings});

  final Widget child;

  /// Where the keyboard mode and the input facts are read; the board's
  /// when null.
  final ScreenSettings? settings;

  /// Show [kind]'s keyboard without a field: the exceptional case (a game
  /// wanting the gamepad, a screen with its own editor). A text kind types
  /// into [editor]; the gamepad sends key events and takes none. It shows
  /// whatever the policy says (it was asked for), stays until
  /// [dismiss] or until a field takes the place, and returns false outside
  /// an applet root.
  static bool show(BuildContext context, {required VrxInputKind kind, VrxTextEditor? editor}) {
    assert(kind == VrxInputKind.gamepad || editor != null, 'a $kind keyboard types into an editor');
    final slot = _SlotScope.maybeOf(context)?.state;
    if (slot == null || kind == VrxInputKind.none) return false;
    slot._attach(_programmatic, kind, editor);
    return true;
  }

  /// Put away whatever keyboard is up, a field's too (its field keeps focus;
  /// a tap on it brings the keyboard back).
  static void dismiss(BuildContext context) => _SlotScope.maybeOf(context)?.state._detach(null);

  /// The owner [show] attaches under.
  static final Object _programmatic = Object();

  @override
  State<VrxKeyboardSlot> createState() => _VrxKeyboardSlotState();
}

class _VrxKeyboardSlotState extends State<VrxKeyboardSlot> {
  late final ScreenSettings _settings = widget.settings ?? ScreenSettings();
  StreamSubscription<VrxInputFacts>? _facts;
  StreamSubscription<ScreenState>? _screen;
  bool _physical = false;
  VrxKeyboardMode _mode = VrxKeyboardMode.auto;

  // what holds the keyboard: its owner, its kind and its editor
  Object? _owner;
  VrxInputKind _kind = VrxInputKind.text;
  VrxTextEditor? _editor;

  @override
  void initState() {
    super.initState();
    _facts = _settings.inputFacts().listen((f) {
      if (mounted && f.keyboard != _physical) setState(() => _physical = f.keyboard);
    }, onError: (Object _) {});
    _screen = _settings.watch().listen((s) {
      if (mounted && s.keyboard != _mode) setState(() => _mode = s.keyboard);
    }, onError: (Object _) {});
  }

  @override
  void dispose() {
    unawaited(_facts?.cancel());
    unawaited(_screen?.cancel());
    super.dispose();
  }

  // a field attaches as focus lands and detaches as it is torn down, which
  // can be inside a build: applied at once when the tree may rebuild, after
  // the frame when it may not
  void _apply(void Function() change) {
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.idle || phase == SchedulerPhase.postFrameCallbacks) {
      if (mounted) setState(change);
      return;
    }
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(change);
    });
    SchedulerBinding.instance.scheduleFrame();
  }

  void _attach(Object owner, VrxInputKind kind, VrxTextEditor? editor) => _apply(() {
        _owner = owner;
        _kind = kind;
        _editor = editor;
      });

  /// Take it back from [owner]; null takes it from whoever holds it.
  void _detach(Object? owner) => _apply(() {
        if (owner != null && _owner != owner) return;
        _owner = null;
        _editor = null;
      });

  @override
  Widget build(BuildContext context) {
    final up = _owner != null;
    return _SlotScope(
      state: this,
      owner: _owner,
      shows: VrxKeyboardPolicy.shows(mode: _mode, physicalKeyboard: _physical),
      child: Column(children: [
        Expanded(child: widget.child),
        if (up) VrxKeyboard(key: ValueKey(_kind), kind: _kind, editor: _editor),
      ]),
    );
  }
}

class _SlotScope extends InheritedWidget {
  const _SlotScope({required this.state, required this.owner, required this.shows, required super.child});

  final _VrxKeyboardSlotState state;
  final Object? owner;
  final bool shows;

  static _SlotScope? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_SlotScope>();

  @override
  bool updateShouldNotify(_SlotScope old) => old.shows != shows || old.state != state || old.owner != owner;
}

/// The kit's text field: every text entry in vrx is one (the scan bans a
/// bare TextField, G072). [kind] says what it holds: it picks the keyboard
/// the field brings up when focused and [VrxKeyboardPolicy] says so, and
/// filters what either keyboard types. [VrxInputKind.none] is a field that
/// brings its own keys (the Scripts editor's terminal keys) and takes none.
///
/// The kit's standard for every field: a cursor, and no selection handles
/// (they sit on the text under a finger; the keyboard edits at the caret).
class VrxTextField extends StatefulWidget {
  const VrxTextField({
    super.key,
    required this.controller,
    this.kind = VrxInputKind.text,
    this.focusNode,
    this.autofocus = false,
    this.maxLines = 1,
    this.expands = false,
    this.style,
    this.decoration = const InputDecoration(),
    this.onSubmitted,
    this.onTap,
  });

  final TextEditingController controller;
  final VrxInputKind kind;
  final FocusNode? focusNode;
  final bool autofocus;

  /// Null grows with the text; with [expands], fills the box. More than one
  /// line makes Enter a newline.
  final int? maxLines;
  final bool expands;
  final TextStyle? style;
  final InputDecoration decoration;

  /// Enter on a one-line field from either keyboard, and A on a gamepad
  /// field.
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onTap;

  @override
  State<VrxTextField> createState() => _VrxTextFieldState();
}

class _VrxTextFieldState extends State<VrxTextField> implements VrxTextEditor {
  FocusNode? _own;
  FocusNode get _focus => widget.focusNode ?? (_own ??= FocusNode(debugLabel: 'vrx text field'));
  _VrxKeyboardSlotState? _slot;
  bool _shows = false;
  bool _attached = false;
  // dismissed, or taken by show(), while focused: no keyboard until a tap or
  // a new focus
  bool _held = false;

  void _onFocus() {
    _held = false;
    _sync();
  }

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
  }

  @override
  void didUpdateWidget(VrxTextField old) {
    super.didUpdateWidget(old);
    if (old.focusNode != widget.focusNode) {
      (old.focusNode ?? _own)?.removeListener(_onFocus);
      _focus.addListener(_onFocus);
    }
    // a new kind on the focused field: its keyboard follows
    if (old.kind != widget.kind && _attached) {
      _attached = false;
    }
    _sync();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = _SlotScope.maybeOf(context);
    if (scope?.state != _slot && _attached) {
      _slot?._detach(this);
      _attached = false;
    }
    _slot = scope?.state;
    _shows = scope?.shows ?? false;
    // another owner (show) took the place, or dismiss emptied it
    if (_attached && scope?.owner != this) {
      _attached = false;
      _held = true;
    }
    _sync();
  }

  void _sync() {
    final want = _focus.hasFocus && _shows && !_held && widget.kind != VrxInputKind.none;
    final slot = _slot;
    if (slot == null || want == _attached) return;
    _attached = want;
    if (want) {
      slot._attach(this, widget.kind, this);
    } else {
      slot._detach(this);
    }
  }

  @override
  void dispose() {
    if (_attached) _slot?._detach(this);
    _focus.removeListener(_onFocus);
    _own?.dispose();
    super.dispose();
  }

  // the editor the keyboard types through: this field's own controller,
  // through the same filter a physical keyboard's typing meets

  static List<TextInputFormatter> _filterFor(VrxInputKind kind) {
    final allowed = kind.allowed;
    return allowed == null ? const [] : [FilteringTextInputFormatter.allow(allowed)];
  }

  @override
  bool get multiline => widget.maxLines != 1;

  TextEditingController get _c => widget.controller;

  @override
  String get text => _c.text;

  TextSelection get _selection =>
      _c.selection.isValid ? _c.selection : TextSelection.collapsed(offset: _c.text.length);

  void _set(TextEditingValue next) {
    var v = next;
    for (final f in _filterFor(widget.kind)) {
      v = f.formatEditUpdate(_c.value, v);
    }
    _c.value = v;
  }

  @override
  void type(String text) {
    final sel = _selection;
    _set(TextEditingValue(
      text: _c.text.replaceRange(sel.start, sel.end, text),
      selection: TextSelection.collapsed(offset: sel.start + text.length),
    ));
  }

  @override
  void replace(String text) =>
      _set(TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length)));

  @override
  void backspace() {
    final sel = _selection;
    if (sel.isCollapsed && sel.start == 0) return;
    final start = sel.isCollapsed ? sel.start - 1 : sel.start;
    _set(TextEditingValue(
      text: _c.text.replaceRange(start, sel.end, ''),
      selection: TextSelection.collapsed(offset: start),
    ));
  }

  @override
  void enter() {
    if (multiline) {
      type('\n');
    } else {
      widget.onSubmitted?.call(_c.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final field = TextField(
      controller: widget.controller,
      focusNode: _focus,
      autofocus: widget.autofocus,
      obscureText: widget.kind == VrxInputKind.password,
      maxLines: widget.kind == VrxInputKind.password ? 1 : widget.maxLines,
      expands: widget.expands,
      keyboardType: widget.maxLines != 1 && widget.kind == VrxInputKind.text
          ? TextInputType.multiline
          : widget.kind.textInputType,
      textInputAction: switch (widget.kind) {
        VrxInputKind.search => TextInputAction.search,
        VrxInputKind.url => TextInputAction.go,
        _ => null,
      },
      inputFormatters: _filterFor(widget.kind),
      style: widget.style,
      decoration: widget.decoration,
      showCursor: true,
      enableInteractiveSelection: false,
      onSubmitted: widget.onSubmitted,
      // a tap on the field it already has: the keyboard is put back if it
      // was dismissed or taken (focus did not change, so the listener is
      // quiet)
      onTap: () {
        _held = false;
        _sync();
        widget.onTap?.call();
      },
    );
    if (widget.kind != VrxInputKind.gamepad) return field;
    // a gamepad field: A submits it (the D-pad's arrows move the caret)
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.gameButtonA) {
          widget.onSubmitted?.call(_c.text);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: field,
    );
  }
}
