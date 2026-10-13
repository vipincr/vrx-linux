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
  Widget build(BuildContext context) {
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
              Expanded(
                child: Text(
                  title,
                  style: TypeRole.of(context, VrxTypeRole.title),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
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
    this.value,
    this.onTap,
  });

  final IconData? glyph;
  final String label;
  final String? value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final palette = VrxTheme.of(context);
    return VrxPress(
      onTap: onTap,
      child: Container(
        constraints: BoxConstraints(
          minHeight: ScaledSpacing.minInteractive(context),
        ),
        padding: EdgeInsets.symmetric(horizontal: ScaledSpacing.of(context).inset),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: palette.line, width: Strokes.hairline)),
        ),
        child: Row(
          children: [
            if (glyph != null) ...[
              Icon(glyph, size: VrxTypeRole.body.dp * VrxScale.of(context)),
              SizedBox(width: ScaledSpacing.of(context).sm),
            ],
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 200), // 2/5 of the UI space; the walk tests own the exact fraction
              child: Text(
                label,
                style: TypeRole.of(context, VrxTypeRole.list),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Spacer(),
            if (value != null)
              Text(
                value!,
                style: TypeRole.of(context, VrxTypeRole.value),
              ),
          ],
        ),
      ),
    );
  }
}

/// A setting's row: the label must read whole — if it would be cut
/// beside the value, the row grows and the value drops to its own
/// line. A setting's label is never cut.
class VrxSettingRow extends StatelessWidget {
  const VrxSettingRow({
    super.key,
    required this.label,
    this.value,
    this.onTap,
  });

  final String label;
  final String? value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final palette = VrxTheme.of(context);
    return VrxPress(
      onTap: onTap,
      child: Container(
        constraints: BoxConstraints(
          minHeight: ScaledSpacing.minInteractive(context),
        ),
        padding: EdgeInsets.symmetric(
          horizontal: ScaledSpacing.of(context).inset,
          vertical: ScaledSpacing.of(context).sm,
        ),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: palette.line, width: Strokes.hairline)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TypeRole.of(context, VrxTypeRole.list),
            ),
            if (value != null)
              Text(
                value!,
                style: TypeRole.of(context, VrxTypeRole.value),
              ),
          ],
        ),
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
        style: TypeRole.of(context, VrxTypeRole.subtext)
            .copyWith(color: palette.onFill),
      ),
    );
  }
}

/// The press micro-interaction: the fill inverts AT ONCE (never
/// faded) and the control sinks to 0.97 scale back on the
/// spatial-fast spring. Wraps any child; press is never eased.
class VrxPress extends StatefulWidget {
  const VrxPress({super.key, required this.child, this.onTap});

  final Widget child;
  final VoidCallback? onTap;

  @override
  State<VrxPress> createState() => _VrxPressState();
}

class _VrxPressState extends State<VrxPress>
    with SingleTickerProviderStateMixin {
  late final AnimationController _scale = AnimationController.unbounded(
    vsync: this,
    value: 1.0,
  );
  bool _held = false;

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
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _set(true),
      onTapUp: (_) => _set(false),
      onTapCancel: () => _set(false),
      onTap: widget.onTap,
      child: ScaleTransition(
        scale: _scale,
        child: _held
            ? ColoredBox(
                color: palette.fill,
                child: DefaultTextStyle(
                  style: TextStyle(color: palette.onFill),
                  child: IconTheme(
                    data: IconThemeData(color: palette.onFill),
                    child: widget.child,
                  ),
                ),
              )
            : widget.child,
      ),
    );
  }
}
