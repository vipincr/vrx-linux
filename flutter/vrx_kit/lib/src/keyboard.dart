/// The on-screen keyboard. vrx boards have no system input method, so a
/// screen that takes text (a Wi-Fi passphrase, a device name) shows this
/// under its field and drives a [TextEditingController] directly; the
/// Terminal takes keystrokes instead ([VrxKeyboard.terminal]).
///
/// Keys are the touch minimum tall (9mm). Across, ten keys share the
/// screen width: on a 43mm panel that is 4.3mm, under the 9mm floor. The
/// keyboard is the one sanctioned exception (AGENTS.md rule 10): a
/// smaller keyboard would need paging, and paging a passphrase loses
/// more taps than narrow keys do. The terminal keyboard is 6mm tall
/// (same rule): five rows at 9mm fill a 57mm panel and leave no output.
library;

import 'package:flutter/material.dart';

import 'input.dart';
import 'metrics.dart';
import 'scale.dart';
import 'symbols.dart';
import 'theme.dart';

enum _Mode { lower, upper, symbols, more }

/// A key the terminal keyboard sends that is not text.
enum VrxTermKey { escape, tab, backspace, enter, left, up, down, right }

/// A keyboard bound to [controller]; [onDone] fires on the done key.
class VrxKeyboard extends StatefulWidget {
  const VrxKeyboard({super.key, required TextEditingController this.controller, this.onDone})
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
  })  : controller = null,
        onDone = null;

  final TextEditingController? controller;
  final VoidCallback? onDone;
  final void Function(String text, {bool ctrl})? onText;
  final void Function(VrxTermKey key)? onKey;
  final VoidCallback? onHide;
  final VoidCallback? onBack;

  @override
  State<VrxKeyboard> createState() => _VrxKeyboardState();
}

class _VrxKeyboardState extends State<VrxKeyboard> {
  _Mode _mode = _Mode.lower;
  bool _ctrl = false;

  static const _letters = ['qwertyuiop', 'asdfghjkl', 'zxcvbnm'];
  static const _symbols = ['1234567890', r'@#$%&*-+()', r'!"' "'" r':;/?_.,'];
  // what a shell and a passphrase need that the first page lacks
  static const _more = [r'[]{}<>|\~^', '=`€£¥°•×÷', '§¶©®¿¡µ'];

  bool get _terminal => widget.controller == null;

  void _type(String text) {
    if (_terminal) {
      widget.onText!(text, ctrl: _ctrl);
      if (_ctrl) setState(() => _ctrl = false);
    } else {
      final c = widget.controller!;
      final sel = c.selection.isValid ? c.selection : TextSelection.collapsed(offset: c.text.length);
      final next = c.text.replaceRange(sel.start, sel.end, text);
      c.value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: sel.start + text.length),
      );
    }
    // one shifted letter, then back to lower case
    if (_mode == _Mode.upper) setState(() => _mode = _Mode.lower);
  }

  void _backspace() {
    if (_terminal) {
      widget.onKey!(VrxTermKey.backspace);
      return;
    }
    final c = widget.controller!;
    final sel = c.selection.isValid ? c.selection : TextSelection.collapsed(offset: c.text.length);
    if (sel.isCollapsed && sel.start == 0) return;
    final start = sel.isCollapsed ? sel.start - 1 : sel.start;
    c.value = TextEditingValue(
      text: c.text.replaceRange(start, sel.end, ''),
      selection: TextSelection.collapsed(offset: start),
    );
  }

  void _enter() => _terminal ? widget.onKey!(VrxTermKey.enter) : widget.onDone?.call();

  @override
  Widget build(BuildContext context) {
    // a physical keyboard is typing: this one steps aside until a finger
    // is back on the panel
    if (VrxHandsScope.of(context) == VrxHands.keys) return const SizedBox.shrink();
    final rows = switch (_mode) {
      _Mode.symbols => _symbols,
      _Mode.more => _more,
      _ => _letters,
    };
    final upper = _mode == _Mode.upper;
    final letters = _mode == _Mode.lower || upper;
    final palette = VrxTheme.of(context);
    final keyHeight = _terminal ? 6 * mmToDp * VrxScale.of(context) : ScaledSpacing.of(context).touch;
    Widget key(String label, VoidCallback onTap, {int flex = 1, IconData? glyph, bool strong = false}) {
      return Expanded(
        flex: flex,
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Material(
            color: strong ? palette.fill.withValues(alpha: 0.28) : palette.highlight,
            borderRadius: BorderRadius.circular(6),
            child: InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: onTap,
              child: SizedBox(
                height: keyHeight,
                child: Center(
                  child: glyph != null
                      ? Icon(glyph, size: keyHeight * 0.45)
                      : Text(label, style: TextStyle(fontSize: keyHeight * 0.38, color: palette.text)),
                ),
              ),
            ),
          ),
        ),
      );
    }

    void term(VrxTermKey k) => widget.onKey!(k);
    return Container(
      color: palette.page,
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_terminal)
            Row(children: [
              key('', widget.onBack!, glyph: VrxSymbols.arrow_back),
              key('esc', () => term(VrxTermKey.escape)),
              key('tab', () => term(VrxTermKey.tab)),
              key('ctrl', () => setState(() => _ctrl = !_ctrl), strong: _ctrl),
              key('', () => term(VrxTermKey.left), glyph: VrxSymbols.keyboard_arrow_left),
              key('', () => term(VrxTermKey.up), glyph: VrxSymbols.keyboard_arrow_up),
              key('', () => term(VrxTermKey.down), glyph: VrxSymbols.keyboard_arrow_down),
              key('', () => term(VrxTermKey.right), glyph: VrxSymbols.keyboard_arrow_right),
              key('', widget.onHide!, glyph: VrxSymbols.keyboard_hide),
            ]),
          for (var r = 0; r < rows.length; r++)
            Row(children: [
              if (r == 2)
                letters
                    ? key('', () => setState(() => _mode = upper ? _Mode.lower : _Mode.upper),
                        flex: 3, glyph: upper ? VrxSymbols.keyboard_capslock : VrxSymbols.arrow_upward)
                    : key(_mode == _Mode.more ? '123' : '#+=',
                        () => setState(() => _mode = _mode == _Mode.more ? _Mode.symbols : _Mode.more),
                        flex: 3),
              for (final ch in rows[r].split(''))
                key(upper ? ch.toUpperCase() : ch, () => _type(upper ? ch.toUpperCase() : ch), flex: 2),
              if (r == 2) key('', _backspace, flex: 3, glyph: VrxSymbols.backspace),
            ]),
          Row(children: [
            key(letters ? '123' : 'abc', () => setState(() => _mode = letters ? _Mode.symbols : _Mode.lower),
                flex: 3),
            key('space', () => _type(' '), flex: 10),
            key('', _enter, flex: 3, glyph: VrxSymbols.keyboard_return, strong: true),
          ]),
        ],
      ),
    );
  }
}
