/// The on-screen keyboard belongs to the field typed into (owner,
/// 2026-10-15). vrx boards have no system input method, so the kit's
/// [VrxTextField] brings its own: focused, it hands the applet root's
/// [VrxKeyboardSlot] a [VrxKeyboard] that edits its own controller, and
/// takes it back when focus leaves. The root only gives the keyboard its
/// place under the screen; no screen and no applet places one.
///
/// Whether a focused field shows it is one decision for every field,
/// [VrxKeyboardPolicy]: never while a physical keyboard is plugged in (the
/// compositor's [VrxInputFacts.keyboard]), unless Settings > Device says
/// Show ([VrxKeyboardMode.show]). A physical keyboard types through the
/// platform's text input, as on any Flutter target.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'keyboard.dart';
import 'screen.dart';

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

  /// Type [text] over the selection.
  void type(String text);

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

  @override
  State<VrxKeyboardSlot> createState() => _VrxKeyboardSlotState();
}

class _VrxKeyboardSlotState extends State<VrxKeyboardSlot> {
  late final ScreenSettings _settings = widget.settings ?? ScreenSettings();
  StreamSubscription<VrxInputFacts>? _facts;
  StreamSubscription<ScreenState>? _screen;
  bool _physical = false;
  VrxKeyboardMode _mode = VrxKeyboardMode.auto;

  // the field holding the keyboard, and its editor
  Object? _owner;
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

  void _attach(Object owner, VrxTextEditor editor) => _apply(() {
        _owner = owner;
        _editor = editor;
      });

  void _detach(Object owner) => _apply(() {
        if (_owner != owner) return;
        _owner = null;
        _editor = null;
      });

  @override
  Widget build(BuildContext context) {
    final editor = _editor;
    return _SlotScope(
      state: this,
      shows: VrxKeyboardPolicy.shows(mode: _mode, physicalKeyboard: _physical),
      child: Column(children: [
        Expanded(child: widget.child),
        if (editor != null) VrxKeyboard(editor: editor),
      ]),
    );
  }
}

class _SlotScope extends InheritedWidget {
  const _SlotScope({required this.state, required this.shows, required super.child});

  final _VrxKeyboardSlotState state;
  final bool shows;

  static _SlotScope? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_SlotScope>();

  @override
  bool updateShouldNotify(_SlotScope old) => old.shows != shows || old.state != state;
}

/// The kit's text field: every text entry in vrx is one (the scan bans a
/// bare TextField, G072). Focused, it brings up the on-screen keyboard when
/// [VrxKeyboardPolicy] says so, typing into [controller]; a
/// [keyboardType] of [TextInputType.none] is a field that brings its own
/// keys (the Scripts editor's terminal keys) and takes none.
///
/// The kit's standard for every field: a cursor, and no selection handles
/// (they sit on the text under a finger; the keyboard edits at the caret).
class VrxTextField extends StatefulWidget {
  const VrxTextField({
    super.key,
    required this.controller,
    this.focusNode,
    this.autofocus = false,
    this.obscureText = false,
    this.maxLines = 1,
    this.expands = false,
    this.keyboardType,
    this.style,
    this.decoration = const InputDecoration(),
    this.onSubmitted,
    this.onTap,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final bool autofocus;

  /// A passphrase: dots, not letters.
  final bool obscureText;

  /// Null grows with the text; with [expands], fills the box.
  final int? maxLines;
  final bool expands;
  final TextInputType? keyboardType;
  final TextStyle? style;
  final InputDecoration decoration;

  /// Enter on a one-line field, from either keyboard.
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

  @override
  void initState() {
    super.initState();
    _focus.addListener(_sync);
  }

  @override
  void didUpdateWidget(VrxTextField old) {
    super.didUpdateWidget(old);
    if (old.focusNode != widget.focusNode) {
      (old.focusNode ?? _own)?.removeListener(_sync);
      _focus.addListener(_sync);
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
    _sync();
  }

  bool get _bringsOwnKeys => widget.keyboardType == TextInputType.none;

  void _sync() {
    final want = _focus.hasFocus && _shows && !_bringsOwnKeys;
    final slot = _slot;
    if (slot == null || want == _attached) return;
    _attached = want;
    if (want) {
      slot._attach(this, this);
    } else {
      slot._detach(this);
    }
  }

  @override
  void dispose() {
    if (_attached) _slot?._detach(this);
    _focus.removeListener(_sync);
    _own?.dispose();
    super.dispose();
  }

  // the editor the keyboard types through: this field's own controller

  @override
  bool get multiline => widget.keyboardType == TextInputType.multiline || widget.maxLines != 1;

  TextEditingController get _c => widget.controller;

  TextSelection get _selection =>
      _c.selection.isValid ? _c.selection : TextSelection.collapsed(offset: _c.text.length);

  @override
  void type(String text) {
    final sel = _selection;
    _c.value = TextEditingValue(
      text: _c.text.replaceRange(sel.start, sel.end, text),
      selection: TextSelection.collapsed(offset: sel.start + text.length),
    );
  }

  @override
  void backspace() {
    final sel = _selection;
    if (sel.isCollapsed && sel.start == 0) return;
    final start = sel.isCollapsed ? sel.start - 1 : sel.start;
    _c.value = TextEditingValue(
      text: _c.text.replaceRange(start, sel.end, ''),
      selection: TextSelection.collapsed(offset: start),
    );
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
    return TextField(
      controller: widget.controller,
      focusNode: _focus,
      autofocus: widget.autofocus,
      obscureText: widget.obscureText,
      maxLines: widget.maxLines,
      expands: widget.expands,
      keyboardType: widget.keyboardType ?? (widget.maxLines == 1 ? null : TextInputType.multiline),
      style: widget.style,
      decoration: widget.decoration,
      showCursor: true,
      enableInteractiveSelection: false,
      onSubmitted: widget.onSubmitted,
      // a tap on the field it already has: the keyboard is put back if
      // another field's took its place (focus did not change, so the
      // listener is quiet)
      onTap: () {
        if (_slot?._owner != this) _attached = false;
        _sync();
        widget.onTap?.call();
      },
    );
  }
}
