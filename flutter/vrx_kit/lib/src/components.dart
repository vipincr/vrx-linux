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

import 'input.dart';
import 'metrics.dart';
import 'motion.dart';
import 'scale.dart';
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
  });

  final String title;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) => VrxBackOffer(onBack: onBack, child: _build(context));

  Widget _build(BuildContext context) {
    final palette = VrxTheme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: ScaledSpacing.of(context).touch,
          child: Row(
            children: [
              if (onBack != null)
                VrxIconButton(
                  glyph: VrxSymbols.arrow_back,
                  onTap: onBack,
                ),
              SizedBox(width: onBack == null ? ScaledSpacing.of(context).inset : ScaledSpacing.of(context).xs),
              Expanded(child: VrxFitText(title, style: TypeRole.of(context, VrxTypeRole.title))),
            ],
          ),
        ),
        Divider(height: Strokes.hairline, thickness: Strokes.hairline, color: palette.line),
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
    final palette = VrxTheme.of(context);
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
          border: Border(bottom: BorderSide(color: palette.line, width: Strokes.hairline)),
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
                    Text(
                      vrxBreakable(second),
                      style: detail != null ? TypeRole.of(context, VrxTypeRole.caption) : valueStyle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
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

/// Mutually exclusive choices; the current one fills (inversion).
/// Selection state is the feedback — no press flash here.
class VrxSegmented extends StatelessWidget {
  const VrxSegmented({
    super.key,
    required this.labels,
    required this.selected,
    this.onSelected,
  });

  final List<String> labels;
  final int selected;
  final ValueChanged<int>? onSelected;

  @override
  Widget build(BuildContext context) {
    final palette = VrxTheme.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: ScaledSpacing.of(context).inset),
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++)
            Expanded(
              child: GestureDetector(
                onTap: onSelected == null ? null : () => onSelected!(i),
                child: Container(
                  margin: EdgeInsets.only(
                    right: i + 1 < labels.length ? ScaledSpacing.of(context).xs : 0,
                  ),
                  padding: EdgeInsets.symmetric(vertical: ScaledSpacing.of(context).sm),
                  decoration: BoxDecoration(
                    color: i == selected ? palette.fill : null,
                    border: Border.all(color: palette.line, width: Strokes.hairline),
                  ),
                  child: Text(
                    labels[i],
                    textAlign: TextAlign.center,
                    style: TypeRole.of(context, VrxTypeRole.list).copyWith(
                      color: i == selected ? palette.onFill : palette.text,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A bordered word, optionally filled (the monochrome ON idiom: a
/// filled chip carries a knocked-out label; an outlined one is OFF).
class VrxChip extends StatelessWidget {
  const VrxChip({super.key, required this.label, this.filled = false, this.onTap});

  final String label;
  final bool filled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final palette = VrxTheme.of(context);
    final s = ScaledSpacing.of(context);
    return VrxPress(
      onTap: onTap,
      child: Container(
        // a control: the touch minimum tall on a touch display
        constraints: BoxConstraints(minHeight: ScaledSpacing.minInteractive(context)),
        alignment: Alignment.centerLeft,
        padding: EdgeInsets.symmetric(horizontal: s.sm, vertical: s.xs),
        decoration: BoxDecoration(
          color: filled ? palette.fill : null,
          border: Border.all(color: palette.line, width: Strokes.hairline),
          borderRadius: BorderRadius.circular(Radii.sm),
        ),
        child: Text(
          label,
          style: TypeRole.of(context, VrxTypeRole.list).copyWith(
            color: filled ? palette.onFill : palette.text,
          ),
        ),
      ),
    );
  }
}

/// A persistent message band across the bottom — deliberately NOT a
/// toast: nothing transient. NULL text slides it away.
class VrxBanner extends StatelessWidget {
  const VrxBanner({super.key, required this.text});

  final String? text;

  @override
  Widget build(BuildContext context) {
    final palette = VrxTheme.of(context);
    if (text == null) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      constraints: BoxConstraints(
        minHeight: ScaledSpacing.minInteractive(context),
      ),
      padding: EdgeInsets.symmetric(
        horizontal: ScaledSpacing.of(context).inset,
        vertical: ScaledSpacing.of(context).sm,
      ),
      color: palette.fill,
      child: Text(
        text!,
        style: TypeRole.of(context, VrxTypeRole.subtext).copyWith(color: palette.onFill),
      ),
    );
  }
}

/// The press micro-interaction: the fill inverts AT ONCE (never
/// faded) and the control sinks to 0.97 scale back on the
/// spatial-fast spring. Wraps any child; press is never eased.
class VrxPress extends StatefulWidget {
  const VrxPress({super.key, required this.child, this.onTap, this.onLongPress});

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

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
    final palette = VrxTheme.of(context);
    final enabled = widget.onTap != null || widget.onLongPress != null;
    Widget child = widget.child;
    if (_held) {
      child = ColoredBox(
        color: palette.fill,
        child: DefaultTextStyle(
          style: TextStyle(color: palette.onFill),
          child: IconTheme(data: IconThemeData(color: palette.onFill), child: child),
        ),
      );
    } else if (_hovered) {
      child = ColoredBox(color: palette.highlight, child: child);
    }
    if (_focused) {
      // the keyboard's place: a ring in the accent, drawn over the
      // control so the layout never moves for it
      child = DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(border: Border.all(color: palette.focus, width: Strokes.border)),
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
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
          widget.onTap?.call();
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

/// [text] with break opportunities after its punctuation (- _ / . &),
/// so an identifier longer than a line wraps between its parts rather
/// than inside a word.
String vrxBreakable(String text) => text.replaceAllMapped(RegExp(r'([-_/.&])'), (m) => '${m[1]}\u200B');

/// Text that fits: one line at [style] when it can, else shrunk to fit
/// one line down to [floor] of its size, else at that size over up to
/// [maxLines] lines, breaking at punctuation. A long network name or
/// package name in a header reads whole instead of ending in "...".
class VrxFitText extends StatelessWidget {
  const VrxFitText(this.text, {super.key, required this.style, this.floor = 0.7, this.maxLines = 2});

  final String text;
  final TextStyle style;
  final double floor;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final scaler = MediaQuery.textScalerOf(context);
      final tp = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final natural = tp.width;
      tp.dispose();
      final base = style.fontSize ?? 14;
      if (natural <= box.maxWidth) return Text(text, style: style, maxLines: 1);
      final scale = box.maxWidth / natural;
      if (scale >= floor) {
        return Text(text, style: style.copyWith(fontSize: base * scale * 0.99), maxLines: 1);
      }
      return Text(
        vrxBreakable(text),
        style: style.copyWith(fontSize: base * floor),
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
      );
    });
  }
}
