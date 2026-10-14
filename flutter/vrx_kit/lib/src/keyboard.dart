/// The on-screen keyboard. vrx boards have no system input method: any
/// text field that takes focus brings this up through the kit's text
/// input control ([VrxKeyboardHost], plan 0013 D6), and no screen places
/// it. A terminal takes keystrokes rather than text, so it shows
/// [VrxKeyboard.terminal] itself.
///
/// Keys are the touch minimum tall (9mm). Across, ten keys share the
/// screen width: on a 43mm panel that is 4.3mm, under the 9mm floor. The
/// keyboard is the one sanctioned exception (AGENTS.md rule 10): a
/// smaller keyboard would need paging, and paging a passphrase loses
/// more taps than narrow keys do. The terminal keyboard is 6mm tall
/// (same rule): five rows at 9mm fill a 57mm panel and leave no output.
library;

import 'package:flutter/material.dart';

import 'components.dart';
import 'input.dart';
import 'metrics.dart';
import 'motion.dart';
import 'scale.dart';
import 'symbols.dart';
import 'text_input.dart';
import 'theme.dart';
import 'ui_standard.g.dart';

enum _Mode { lower, upper, symbols, more }

/// A key the terminal keyboard sends that is not text.
enum VrxTermKey { escape, tab, backspace, enter, left, up, down, right }

/// The text keyboard, typing into the focused field through [input].
class VrxKeyboard extends StatefulWidget {
  const VrxKeyboard({super.key, required VrxTextInputControl this.input})
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
  }) : input = null;

  final VrxTextInputControl? input;
  final void Function(String text, {bool ctrl})? onText;
  final void Function(VrxTermKey key)? onKey;
  final VoidCallback? onHide;
  final VoidCallback? onBack;

  /// The text keyboard's height: four rows of touch-minimum keys 1mm
  /// apart, and a 1mm edge above and below.
  static double heightOf(BuildContext context) =>
      4 * (ScaledSpacing.of(context).touch + ScaledSpacing.of(context).xs) + 2 * ScaledSpacing.of(context).xs;

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

  bool get _terminal => widget.input == null;

  void _type(String text) {
    if (_terminal) {
      widget.onText!(text, ctrl: _ctrl);
      if (_ctrl) setState(() => _ctrl = false);
    } else {
      widget.input!.type(text);
    }
    // one shifted letter, then back to lower case
    if (_mode == _Mode.upper) setState(() => _mode = _Mode.lower);
  }

  void _backspace() {
    if (_terminal) {
      widget.onKey!(VrxTermKey.backspace);
      return;
    }
    widget.input!.backspace();
  }

  void _enter() => _terminal ? widget.onKey!(VrxTermKey.enter) : widget.input!.enter();

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
    final colors = VrxTheme.of(context);
    final keyHeight = _terminal ? 6 * mmToDp * VrxScale.of(context) : ScaledSpacing.of(context).touch;
    Widget key(String label, VoidCallback onTap, {int flex = 1, IconData? glyph, bool strong = false}) {
      return Expanded(
        flex: flex,
        child: Padding(
          // half the 1mm gutter each side: keys stand 1mm apart
          padding: EdgeInsets.all(Spacing.xs / 2 * VrxScale.of(context)),
          // the kit's press, as every control: acknowledged the same way; a
          // character key also pops a preview above it (micro.key)
          child: _KeyPop(
            height: keyHeight,
            enabled: glyph == null,
            preview: Container(
              height: keyHeight,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: colors.surfaceHigh,
                border: Border.all(color: colors.outline, width: Strokes.hairline),
                borderRadius: BorderRadius.circular(Radii.sm * VrxScale.of(context)),
              ),
              child: Text(label,
                  maxLines: 1,
                  style: TypeRole.of(context, VrxTypeRole.list).copyWith(fontSize: keyHeight * 0.38, color: colors.text)),
            ),
            child: VrxPress(
              onTap: onTap,
              label: label,
              child: Container(
                height: keyHeight,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: strong ? colors.secondaryContainer : colors.surfaceHigh,
                  borderRadius: BorderRadius.circular(Radii.sm * VrxScale.of(context)),
                ),
                // a key is an instrument: its label is sized to the key, which
                // is sized from the scale (the touch minimum, or 6mm on the
                // terminal's row); the face is the value role's
                child: glyph != null
                    ? Icon(glyph, size: keyHeight * 0.45)
                    // one line always: a narrow key shrinks its word, never wraps it
                    : FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(label,
                            maxLines: 1,
                            style: TypeRole.of(context, VrxTypeRole.list).copyWith(fontSize: keyHeight * 0.38, color: colors.text)),
                      ),
              ),
            ),
          ),
        ),
      );
    }

    void term(VrxTermKey k) => widget.onKey!(k);
    return _LayerFade(
      // letters (either case), symbols and the extra page are three layers
      layer: letters ? 0 : _mode.index,
      child: Container(
      color: colors.page,
      padding: EdgeInsets.symmetric(horizontal: ScaledSpacing.of(context).xs / 2, vertical: ScaledSpacing.of(context).xs),
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
          Row(children: [
            key(letters ? '123' : 'abc', () => setState(() => _mode = letters ? _Mode.symbols : _Mode.lower),
                flex: 3),
            key('space', () => _type(' '), flex: 10),
            key('Enter', _enter, flex: 3, glyph: VrxSymbols.keyboard_return, strong: true),
          ]),
        ],
      ),
    ),
    );
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
