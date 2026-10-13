/// The on-screen keyboard. vrx boards have no system input method, so a
/// screen that takes text (a Wi-Fi passphrase, a device name) shows this
/// under its field and drives a [TextEditingController] directly.
///
/// Keys are the touch minimum tall (9mm). Across, ten keys share the
/// screen width: on a 43mm panel that is 4.3mm, under the 9mm floor. The
/// keyboard is the one sanctioned exception (AGENTS.md rule 10): a
/// smaller keyboard would need paging, and paging a passphrase loses
/// more taps than narrow keys do.
library;

import 'package:flutter/material.dart';

import 'scale.dart';
import 'symbols.dart';
import 'theme.dart';

enum _Mode { lower, upper, symbols }

/// A keyboard bound to [controller]; [onDone] fires on the done key.
class VrxKeyboard extends StatefulWidget {
  const VrxKeyboard({super.key, required this.controller, this.onDone});

  final TextEditingController controller;
  final VoidCallback? onDone;

  @override
  State<VrxKeyboard> createState() => _VrxKeyboardState();
}

class _VrxKeyboardState extends State<VrxKeyboard> {
  _Mode _mode = _Mode.lower;

  static const _letters = ['qwertyuiop', 'asdfghjkl', 'zxcvbnm'];
  static const _symbols = ['1234567890', r'@#$%&*-+()', r'!"' "'" r':;/?_.,'];

  void _type(String text) {
    final c = widget.controller;
    final sel = c.selection.isValid ? c.selection : TextSelection.collapsed(offset: c.text.length);
    final next = c.text.replaceRange(sel.start, sel.end, text);
    c.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: sel.start + text.length),
    );
    // one shifted letter, then back to lower case
    if (_mode == _Mode.upper) setState(() => _mode = _Mode.lower);
  }

  void _backspace() {
    final c = widget.controller;
    final sel = c.selection.isValid ? c.selection : TextSelection.collapsed(offset: c.text.length);
    if (sel.isCollapsed && sel.start == 0) return;
    final start = sel.isCollapsed ? sel.start - 1 : sel.start;
    c.value = TextEditingValue(
      text: c.text.replaceRange(start, sel.end, ''),
      selection: TextSelection.collapsed(offset: start),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rows = _mode == _Mode.symbols ? _symbols : _letters;
    final upper = _mode == _Mode.upper;
    final palette = VrxTheme.of(context);
    final keyHeight = ScaledSpacing.of(context).touch;
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

    return Container(
      color: palette.page,
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var r = 0; r < rows.length; r++)
            Row(children: [
              if (r == 2 && _mode != _Mode.symbols)
                key('', () => setState(() => _mode = upper ? _Mode.lower : _Mode.upper),
                    flex: 3, glyph: upper ? VrxSymbols.keyboard_capslock : VrxSymbols.arrow_upward),
              for (final ch in rows[r].split(''))
                key(upper ? ch.toUpperCase() : ch, () => _type(upper ? ch.toUpperCase() : ch), flex: 2),
              if (r == 2) key('', _backspace, flex: 3, glyph: VrxSymbols.backspace),
            ]),
          Row(children: [
            key(_mode == _Mode.symbols ? 'abc' : '123',
                () => setState(() => _mode = _mode == _Mode.symbols ? _Mode.lower : _Mode.symbols),
                flex: 3),
            key('space', () => _type(' '), flex: 10),
            key('', widget.onDone ?? () {}, flex: 3, glyph: VrxSymbols.keyboard_return, strong: true),
          ]),
        ],
      ),
    );
  }
}
