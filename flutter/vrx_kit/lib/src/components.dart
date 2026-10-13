/// The vrx component library, ported from evrx-rt's `ui_kit` — the
/// workhorse family with its contracts. The numbers come from
/// metrics.dart (the shared standard); the semantics come from the
/// evrx-rt spec:
///
/// - a row is 100% × the touch minimum, edge-inset padding, hairline
///   under; an inert row is a status line, never a disabled button
/// - a setting's label is never cut (it wraps; the value drops under)
/// - a selected segment FILLS (inversion); selection state is the
///   feedback — no press flash on selection controls
/// - the banner is persistent (a sentence across the bottom), never a
///   toast: nothing transient
/// - press feedback inverts AT ONCE and sinks to 0.97 scale on the
///   spatial-fast spring — press is never eased on any panel
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'input.dart';
import 'metrics.dart';
import 'motion.dart';
import 'scale.dart';
import 'shell.dart';
import 'symbols.dart';
import 'theme.dart';

/// The screen's own name with a back chevron: full width × the touch
/// minimum, hairline under, chevron left, title at LIST past a touch
/// minimum of offset.
class VrxHeader extends StatelessWidget {
  const VrxHeader({
    super.key,
    required this.title,
    this.onBack,
    this.action,
  });

  final String title;
  final VoidCallback? onBack;

  /// One control at the header's end (a mode the whole screen is in).
  final Widget? action;

  // the back offer stays while the strip shows: the strip's Back calls it
  @override
  Widget build(BuildContext context) => VrxBackOffer(
        onBack: onBack,
        child: ListenableBuilder(listenable: VrxShell.changes, builder: (context, _) => _build(context)),
      );

  Widget _build(BuildContext context) {
    final colors = VrxTheme.of(context);
    // one Back on screen: the shell's strip has it while it shows
    final arrow = onBack != null && !VrxShell.stripShown;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: ScaledSpacing.of(context).touch,
          child: Row(
            children: [
              if (arrow)
                VrxIconButton(
                  glyph: VrxSymbols.arrow_back,
                  onTap: onBack,
                ),
              SizedBox(width: arrow ? ScaledSpacing.of(context).xs : ScaledSpacing.of(context).inset),
              Expanded(child: VrxFitText(title, style: TypeRole.of(context, VrxTypeRole.title))),
              if (action != null) ...[
                action!,
                SizedBox(width: ScaledSpacing.of(context).inset),
              ],
            ],
          ),
        ),
        Divider(height: Strokes.hairline, thickness: Strokes.hairline, color: colors.outlineFaint),
      ],
    );
  }
}

/// A square icon button: 5mm, glyph centred, inverts while held.
class VrxIconButton extends StatelessWidget {
  const VrxIconButton({super.key, required this.glyph, this.onTap});

  final IconData glyph;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    // the glyph is the 5mm chrome square; the hit area is the touch
    // minimum around it (on a touch display), so Back is never a 5mm aim
    final hit = ScaledSpacing.minInteractive(context);
    final square = Chrome.iconButton * VrxScale.of(context);
    return VrxPress(
      onTap: onTap,
      child: SizedBox(
        width: hit > square ? hit : square,
        height: hit > square ? hit : square,
        child: Icon(glyph, size: square),
      ),
    );
  }
}

/// The default screen shape: a vertical list, paged not dragged, no
/// scrollbar. One gesture moves one screenful minus the page overlap.
class VrxList extends StatelessWidget {
  const VrxList({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemCount: children.length,
      // paged feel: no scrollbar ever, and the physics snapps a page
      // per gesture (custom ScrollPhysics lands with the walk tests)
      padding: EdgeInsets.zero,
      itemBuilder: (context, i) => children[i],
    );
  }
}

/// A labelled group in a list: not tappable, visually separated.
class VrxSection extends StatelessWidget {
  const VrxSection({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: ScaledSpacing.of(context).inset,
        right: ScaledSpacing.of(context).inset,
        top: ScaledSpacing.of(context).md,
        bottom: ScaledSpacing.of(context).xs,
      ),
      child: Text(
        title.toUpperCase(),
        style: TypeRole.of(context, VrxTypeRole.subtext),
      ),
    );
  }
}

/// The workhorse row: 100% × the touch minimum, edge insets, hairline
/// under, optional glyph, label at LIST (capped at 2/5 width), value
/// at VALUE right-aligned. `onTap == null` is an inert status line —
/// never a styled-disabled button.
class VrxRow extends StatelessWidget {
  const VrxRow({
    super.key,
    this.glyph,
    required this.label,
    this.detail,
    this.value,
    this.valueGlyph,
    this.onValueGlyph,
    this.onTap,
    this.onLongPress,
  });

  final IconData? glyph;
  final String label;

  /// A second line under the label (a package's licence, a network's
  /// address); with it, label and detail each take two lines before
  /// giving way, and long identifiers break at their punctuation.
  final String? detail;
  final String? value;

  /// A glyph after the value (a lock on a secured network): a symbol
  /// from the icon font, never an emoji (the image ships no emoji font).
  final IconData? valueGlyph;

  /// Makes [valueGlyph] its own control, a touch minimum square apart
  /// from the row's tap (an alarm's bell switches it; the row edits it).
  final VoidCallback? onValueGlyph;
  final VoidCallback? onTap;

  /// A hold: for what a tap must not do by accident (removing a row,
  /// after a confirm).
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final colors = VrxTheme.of(context);
    final glyphSize = VrxTypeRole.value.dp * VrxScale.of(context);
    final hasValue = value != null && value!.isNotEmpty;
    return VrxPress(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        constraints: BoxConstraints(
          minHeight: ScaledSpacing.minInteractive(context),
        ),
        padding: EdgeInsets.symmetric(horizontal: ScaledSpacing.of(context).inset),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: colors.outlineFaint, width: Strokes.hairline)),
        ),
        // label and value side by side when both fit whole; when not,
        // the row grows and the value drops under the label (a setting's
        // label is never cut, and neither is a zone or a board's name)
        child: LayoutBuilder(builder: (context, box) {
          final space = ScaledSpacing.of(context);
          final labelStyle = TypeRole.of(context, VrxTypeRole.list);
          final valueStyle = TypeRole.of(context, VrxTypeRole.value);
          final scaler = MediaQuery.textScalerOf(context);
          double width(String text, TextStyle style) {
            final tp = TextPainter(
              text: TextSpan(text: text, style: style),
              textDirection: TextDirection.ltr,
              textScaler: scaler,
              maxLines: 1,
            )..layout();
            final w = tp.width;
            tp.dispose();
            return w;
          }

          final lead = glyph == null ? 0.0 : VrxTypeRole.body.dp * VrxScale.of(context) + space.sm;
          final trail = valueGlyph == null
              ? 0.0
              : (onValueGlyph != null ? ScaledSpacing.minInteractive(context) : glyphSize + space.xs);
          final room = box.maxWidth - lead - trail;
          final stacked = detail != null ||
              (hasValue && width(label, labelStyle) + space.sm + width(value!, valueStyle) > room) ||
              (!hasValue && width(label, labelStyle) > room);
          final trailing = [
            if (valueGlyph != null && onValueGlyph != null)
              VrxPress(
                onTap: onValueGlyph,
                child: SizedBox.square(
                  dimension: ScaledSpacing.minInteractive(context),
                  child: Icon(valueGlyph, size: glyphSize),
                ),
              )
            else if (valueGlyph != null) ...[
              SizedBox(width: space.xs),
              Icon(valueGlyph, size: glyphSize),
            ],
          ];
          final leading = [
            if (glyph != null) ...[
              Icon(glyph, size: VrxTypeRole.body.dp * VrxScale.of(context)),
              SizedBox(width: space.sm),
            ],
          ];
          if (!stacked) {
            return Row(children: [
              ...leading,
              Expanded(child: Text(label, style: labelStyle, maxLines: 1)),
              if (hasValue) ...[SizedBox(width: space.sm), Text(value!, style: valueStyle, maxLines: 1)],
              ...trailing,
            ]);
          }
          final second = detail ?? value;
          return Row(children: [
            ...leading,
            Expanded(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: space.xs),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  VrxFitText(label, style: labelStyle),
                  if (second != null && second.isNotEmpty)
                    VrxRevealText(
                      vrxBreakable(second),
                      style: detail != null ? TypeRole.of(context, VrxTypeRole.caption) : valueStyle,
                      maxLines: 2,
                      // a row that does something keeps its tap; an inert
                      // one shows the rest of a cut value on a tap
                      reveals: onTap == null && onLongPress == null,
                    ),
                ]),
              ),
            ),
            if (detail != null && hasValue) ...[
              SizedBox(width: space.sm),
              Text(value!, style: valueStyle, maxLines: 1)
            ],
            ...trailing,
          ]);
        }),
      ),
    );
  }
}

/// One choice of a few, side by side (evrx-rt docs/13 §Segmented): the
/// chosen cell is filled AND framed (never the colour alone, which a grey
/// panel cannot show); choosing does not also flash (a flash would claim
/// both cells for a refresh); every cell is as wide as the widest label
/// needs, and a row too narrow shrinks every label alike, never cuts one.
/// It takes focus: the arrows move the choice, as a finger would. With
/// [glyphs] the cells show those instead, the labels naming them for a
/// screen reader.
class VrxSegmented extends StatefulWidget {
  const VrxSegmented({
    super.key,
    required this.labels,
    required this.selected,
    this.onSelected,
    this.glyphs,
  }) : assert(glyphs == null || glyphs.length == labels.length);

  final List<String> labels;
  final List<IconData>? glyphs;
  final int selected;
  final ValueChanged<int>? onSelected;

  @override
  State<VrxSegmented> createState() => _VrxSegmentedState();
}

class _VrxSegmentedState extends State<VrxSegmented> {
  bool _focused = false;

  void _step(int by) {
    final next = (widget.selected + by).clamp(0, widget.labels.length - 1);
    if (next != widget.selected) widget.onSelected?.call(next);
  }

  @override
  Widget build(BuildContext context) {
    final colors = VrxTheme.of(context);
    final s = ScaledSpacing.of(context);
    final style = TypeRole.of(context, VrxTypeRole.list);
    final enabled = widget.onSelected != null;
    return FocusableActionDetector(
      enabled: enabled,
      onShowFocusHighlight: (v) => setState(() => _focused = v),
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.arrowLeft): _StepIntent(-1),
        SingleActivator(LogicalKeyboardKey.arrowRight): _StepIntent(1),
      },
      actions: {
        _StepIntent: CallbackAction<_StepIntent>(onInvoke: (i) {
          _step(i.by);
          return null;
        }),
      },
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: s.inset),
        child: LayoutBuilder(builder: (context, box) {
          final gaps = s.xs * (widget.labels.length - 1);
          final cell = (box.maxWidth - gaps) / widget.labels.length - 2 * s.sm;
          final scaler = MediaQuery.textScalerOf(context);
          var widest = 0.0;
          for (final l in widget.labels) {
            final tp = TextPainter(
              text: TextSpan(text: l, style: style),
              textDirection: TextDirection.ltr,
              textScaler: scaler,
              maxLines: 1,
            )..layout();
            if (tp.width > widest) widest = tp.width;
          }
          // one scale for every label: the widest decides
          final fit = widest > cell && widest > 0 ? cell / widest : 1.0;
          return Row(children: [
            for (var i = 0; i < widget.labels.length; i++)
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: enabled ? () => widget.onSelected!(i) : null,
                  child: Container(
                    margin: EdgeInsets.only(right: i + 1 < widget.labels.length ? s.xs : 0),
                    constraints: BoxConstraints(minHeight: ScaledSpacing.minInteractive(context)),
                    alignment: Alignment.center,
                    padding: EdgeInsets.symmetric(horizontal: s.sm, vertical: s.sm),
                    decoration: BoxDecoration(
                      // segments rest on the secondary container; the chosen
                      // one is the primary, and framed
                      color: i == widget.selected ? colors.primary : colors.secondaryContainer,
                      border: Border.all(
                        color: i == widget.selected
                            ? (_focused ? colors.focus : colors.outline)
                            : (colors.secondaryContainer == colors.page ? colors.outlineFaint : colors.secondaryContainer),
                        width: i == widget.selected ? Strokes.border : Strokes.hairline,
                      ),
                    ),
                    child: widget.glyphs != null
                        ? Icon(
                            widget.glyphs![i],
                            semanticLabel: widget.labels[i],
                            size: ScaledSpacing.of(context).touch * 0.5,
                            color: i == widget.selected ? colors.onPrimary : colors.onSecondaryContainer,
                          )
                        : Text(
                            widget.labels[i],
                            maxLines: 1,
                            softWrap: false,
                            textAlign: TextAlign.center,
                            style: style.copyWith(
                              fontSize: (style.fontSize ?? 14) * fit,
                              color: i == widget.selected ? colors.onPrimary : colors.onSecondaryContainer,
                            ),
                          ),
                  ),
                ),
              ),
          ]);
        }),
      ),
    );
  }
}

class _StepIntent extends Intent {
  const _StepIntent(this.by);

  final int by;
}

/// A word to tap: filled in the primary for the screen's action, resting on
/// the secondary container otherwise (evrx-rt's chip); on a grey panel the
/// container is the page and the chip keeps its frame. With no [onTap] it
/// is disabled: it loses its fill and frame and keeps its word in the
/// ink (evrx-rt docs/13: never grey text, which a first e-paper pass and
/// a dim panel both lose).
class VrxChip extends StatelessWidget {
  const VrxChip({super.key, required this.label, this.filled = false, this.onTap});

  final String label;
  final bool filled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = VrxTheme.of(context);
    final s = ScaledSpacing.of(context);
    return VrxPress(
      onTap: onTap,
      onFill: filled,
      child: Container(
        // a control: the touch minimum tall on a touch display
        constraints: BoxConstraints(minHeight: ScaledSpacing.minInteractive(context)),
        alignment: Alignment.centerLeft,
        padding: EdgeInsets.symmetric(horizontal: s.sm, vertical: s.xs),
        decoration: onTap == null
            ? null
            : BoxDecoration(
                color: filled ? colors.primary : colors.secondaryContainer,
                // a container the page's own grey needs a frame to be seen
                border: colors.secondaryContainer == colors.page
                    ? Border.all(color: colors.outline, width: Strokes.hairline)
                    : null,
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
        child: Text(
          label,
          style: TypeRole.of(context, VrxTypeRole.list).copyWith(
            color: onTap == null ? colors.text : (filled ? colors.onPrimary : colors.onSecondaryContainer),
          ),
        ),
      ),
    );
  }
}

/// A persistent message band across the bottom — deliberately NOT a
/// toast: nothing transient. NULL text slides it away; with [onTap], a
/// tap on it does too (the person read it).
class VrxBanner extends StatelessWidget {
  const VrxBanner({super.key, required this.text, this.signal = VrxSignal.error, this.onTap});

  final String? text;
  final VoidCallback? onTap;

  /// What it means: its colour and its glyph, never the colour alone.
  final VrxSignal signal;

  @override
  Widget build(BuildContext context) {
    final colors = VrxTheme.of(context);
    if (text == null) return const SizedBox.shrink();
    final band = Container(
      width: double.infinity,
      constraints: BoxConstraints(
        minHeight: ScaledSpacing.minInteractive(context),
      ),
      padding: EdgeInsets.symmetric(
        horizontal: ScaledSpacing.of(context).inset,
        vertical: ScaledSpacing.of(context).sm,
      ),
      color: colors[signal.slot],
      child: Row(children: [
        Icon(signal.glyph, size: Chrome.statusButton * VrxScale.of(context), color: colors.on(signal.slot)),
        SizedBox(width: ScaledSpacing.of(context).sm),
        Expanded(
          child: Text(
            text!,
            style: TypeRole.of(context, VrxTypeRole.subtext).copyWith(color: colors.on(signal.slot)),
          ),
        ),
      ]),
    );
    return onTap == null ? band : GestureDetector(onTap: onTap, child: band);
  }
}

/// The press micro-interaction, answered by the display class (plan 0009
/// D8): a state layer of the primary on a lit panel, the inversion on a
/// grey one, AT ONCE (never faded), and the control sinks to 0.97 scale
/// back on the spatial-fast spring. Wraps any child; press is never eased.
///
/// A control that is already filled with the primary says so ([onFill]):
/// a primary layer over the primary changes nothing a person can see, so
/// its press is drawn in the primary's own ink instead (evrx-rt docs/15
/// §7: feedback must change what is drawn).
///
/// What a hold does, a keyboard does with Shift+Enter or the Menu key,
/// and a mouse with a right click: every control is reachable without a
/// finger (evrx-rt AGENTS.md 2.1.2a).
class VrxPress extends StatefulWidget {
  const VrxPress({super.key, required this.child, this.onTap, this.onLongPress, this.onFill = false});

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// The child is filled with the primary.
  final bool onFill;

  @override
  State<VrxPress> createState() => _VrxPressState();
}

class _VrxPressState extends State<VrxPress> with SingleTickerProviderStateMixin {
  late final AnimationController _scale = AnimationController.unbounded(
    vsync: this,
    value: 1.0,
  );
  bool _held = false;
  bool _focused = false;
  bool _hovered = false;

  @override
  void dispose() {
    _scale.dispose();
    super.dispose();
  }

  void _set(bool held) {
    if (_held == held) return;
    setState(() => _held = held);
    // retarget keeps velocity: animateWith re-seeds from the current
    // position, mid-flight continuity by construction
    _scale.animateWith(
      MotionTokens.simulate(
        MotionTokens.spatialFast,
        _scale.value,
        held ? 0.97 : 1.0,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = VrxTheme.of(context);
    final enabled = widget.onTap != null || widget.onLongPress != null;
    Widget child = widget.child;
    final layer = colors.classRow.pressedLayerPermille;
    // on a filled control the layer and the inversion use the ink the
    // fill is read with, or nothing would change
    final fill = widget.onFill ? colors.onPrimary : colors.primary;
    final ink = widget.onFill ? colors.primary : colors.onPrimary;
    if (_held && layer > 0) {
      // a lit panel: the primary laid over the control at the class's
      // strength, its words as they were (a whole control turning to its
      // ink for a tap read as a flicker on evrx-rt's first colour board)
      child = DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(color: fill.withValues(alpha: (widget.onFill ? 2 : 1) * layer / 1000)),
        child: child,
      );
    } else if (_held) {
      // a grey or one-bit panel: the inversion, one partial refresh
      child = ColoredBox(
        color: fill,
        child: DefaultTextStyle(
          style: TextStyle(color: ink),
          child: IconTheme(data: IconThemeData(color: ink), child: child),
        ),
      );
    } else if (_hovered) {
      child = ColoredBox(color: colors.surfaceHigh, child: child);
    }
    if (_focused) {
      // the keyboard's place: a ring in the accent, drawn over the
      // control so the layout never moves for it
      child = DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(border: Border.all(color: colors.focus, width: Strokes.border)),
        child: child,
      );
    }
    // a mouse and keyboard reach it too: focus (Tab, the arrows), Enter
    // or Space to press, hover, and a right click for what a hold does
    return FocusableActionDetector(
      enabled: enabled,
      mouseCursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onShowFocusHighlight: (v) => setState(() => _focused = v),
      onShowHoverHighlight: (v) => setState(() => _hovered = v),
      shortcuts: widget.onLongPress == null
          ? null
          : const {
              SingleActivator(LogicalKeyboardKey.enter, shift: true): _HoldIntent(),
              SingleActivator(LogicalKeyboardKey.contextMenu): _HoldIntent(),
            },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
          widget.onTap?.call();
          return null;
        }),
        _HoldIntent: CallbackAction<_HoldIntent>(onInvoke: (_) {
          widget.onLongPress?.call();
          return null;
        }),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _set(true),
        onTapUp: (_) => _set(false),
        onTapCancel: () => _set(false),
        onTap: widget.onTap,
        onLongPress: widget.onLongPress == null
            ? null
            : () {
                _set(false);
                widget.onLongPress!();
              },
        onSecondaryTap: widget.onLongPress,
        child: ScaleTransition(scale: _scale, child: child),
      ),
    );
  }
}

/// What a hold does, from the keyboard.
class _HoldIntent extends Intent {
  const _HoldIntent();
}

/// [text] with break opportunities after its punctuation (- _ / . &),
/// so an identifier longer than a line wraps between its parts rather
/// than inside a word.
String vrxBreakable(String text) => text.replaceAllMapped(RegExp(r'([-_/.&])'), (m) => '${m[1]}\u200B');

/// Text that fits: one line at [style] when it can, else shrunk to fit
/// one line down to [floor] of its size, else at that size over up to
/// [maxLines] lines, breaking at punctuation. A long network name or
/// package name in a header reads whole instead of ending in "...".
class VrxFitText extends StatelessWidget {
  const VrxFitText(this.text,
      {super.key, required this.style, this.floor = 0.7, this.maxLines = 2, this.textAlign, this.widest});

  final String text;

  /// The widest text this slot will ever hold ("88:88" for a clock): the
  /// size is fitted to it, so the text does not change size as its value
  /// changes (evrx-rt docs/13 §Text that did not fit).
  final String? widest;
  final TextStyle style;
  final double floor;
  final int maxLines;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final scaler = MediaQuery.textScalerOf(context);
      final tp = TextPainter(
        text: TextSpan(text: widest ?? text, style: style),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final natural = tp.width;
      tp.dispose();
      final base = style.fontSize ?? 14;
      if (natural <= box.maxWidth) return Text(text, style: style, maxLines: 1, textAlign: textAlign);
      final scale = box.maxWidth / natural;
      if (scale >= floor) {
        return Text(text, style: style.copyWith(fontSize: base * scale * 0.99), maxLines: 1, textAlign: textAlign);
      }
      // still too long: the lines it has, and a tap shows the rest
      return VrxRevealText(
        vrxBreakable(text),
        style: style.copyWith(fontSize: base * floor),
        maxLines: maxLines,
        textAlign: textAlign,
      );
    });
  }
}

/// Text cut to [maxLines] that a tap shows whole, and a second tap cuts
/// again (evrx-rt docs/13 §Cut text: an ellipsis is a promise that the
/// rest can be seen). Text that fits is plain text; with [reveals] false
/// it only cuts (its parent's tap does something else).
class VrxRevealText extends StatefulWidget {
  const VrxRevealText(this.text, {super.key, required this.style, this.maxLines = 2, this.textAlign, this.reveals = true});

  final String text;
  final TextStyle style;
  final int maxLines;
  final TextAlign? textAlign;
  final bool reveals;

  @override
  State<VrxRevealText> createState() => _VrxRevealTextState();
}

class _VrxRevealTextState extends State<VrxRevealText> {
  bool _whole = false;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final tp = TextPainter(
        text: TextSpan(text: widget.text, style: widget.style),
        textDirection: TextDirection.ltr,
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: widget.maxLines,
      )..layout(maxWidth: box.maxWidth);
      final cut = tp.didExceedMaxLines;
      tp.dispose();
      final text = Text(
        widget.text,
        style: widget.style,
        maxLines: _whole ? null : widget.maxLines,
        overflow: _whole ? null : TextOverflow.ellipsis,
        textAlign: widget.textAlign,
      );
      if (!cut || !widget.reveals) return text;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _whole = !_whole),
        child: text,
      );
    });
  }
}

/// Marks text that may end in an ellipsis by design (Home's tile titles:
/// one size on every tile, two lines at most, the rest hidden; the owner,
/// 2026-10-13). vrx_check's "cut" rule passes text under it; everywhere
/// else a cut word is a layout bug.
class VrxTruncates extends StatelessWidget {
  const VrxTruncates({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}
