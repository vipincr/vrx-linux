/// The status strip: the shell's chrome across the top — the host
/// applet's whole screen in evrx-rt, ported as the kit's chrome
/// widget. Facts in, glyphs out: the strip's owner passes WHAT is
/// true (clock set, wifi up, battery level) and this widget draws
/// the observation; it never decides policy (a low battery draws no
/// warning triangle here — that glyph belongs to whoever owns the
/// policy).
///
/// Left to right: back (offered, not asserted), the clock and the day
/// (all the width the rest leaves), then at the end wifi, ble (hidden
/// when down: an always-present glyph says nothing) and the battery cell
/// (glyph and percent, `~` while estimated). Hairline under; edge insets;
/// the height is heightOf's.
library;

import 'package:flutter/material.dart';

import 'components.dart';
import 'metrics.dart';
import 'scale.dart';
import 'symbols.dart';
import 'theme.dart';

/// What is true; the strip draws it.
class VrxStatusFacts {
  const VrxStatusFacts({
    this.showBack = false,
    this.onBack,
    this.clockText,
    this.dateText,
    this.wifiUp = false,
    this.bleUp = false,
    this.batteryLevel,
    this.batteryCharging = false,
    this.batteryEstimated = false,
  });

  /// The Back affordance is offered (there is somewhere to go).
  final bool showBack;
  final VoidCallback? onBack;

  /// "--:--" when unset; the caller formats the hour.
  final String? clockText;

  /// The day beside the clock ("Tue 13 Oct"); dropped first when the
  /// strip is narrow.
  final String? dateText;

  final bool wifiUp;
  final bool bleUp;

  /// 0-100; null = unknown.
  final int? batteryLevel;
  final bool batteryCharging;

  /// The reading is an estimate: the percent renders with `~`.
  final bool batteryEstimated;
}

class VrxStatusStrip extends StatelessWidget {
  const VrxStatusStrip({super.key, required this.facts});

  final VrxStatusFacts facts;

  /// The strip's height on this display, in logical px: evrx-rt's 6mm,
  /// but never under the touch minimum on a touch display (its Back is a
  /// control; the layout check found it at 4mm on every touch panel),
  /// the hairline under it extra. Apps are laid out below it.
  static double heightOf(BuildContext context) => (Chrome.statusHeight * VrxScale.of(context))
      .clamp(ScaledSpacing.minInteractive(context) + Strokes.hairline, double.infinity);

  @override
  Widget build(BuildContext context) {
    final colors = VrxTheme.of(context);
    final s = ScaledSpacing.of(context);
    return Container(
      height: heightOf(context),
      // no breathing room above and below a touch-height strip: it would
      // squeeze the Back control under the minimum again
      padding: EdgeInsets.symmetric(
        horizontal: s.inset,
        vertical: ScaledSpacing.minInteractive(context) > 0 ? 0 : s.xs,
      ),
      // opaque: on the board it is the shell's, on a plane above the app
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(
          bottom: BorderSide(color: colors.outlineFaint, width: Strokes.hairline),
        ),
      ),
      child: Row(
        children: [
          // back (offered, not asserted): its own slot, the strip's
          // full height and half again the touch minimum wide, so a
          // finger near the arrow goes back instead of falling through
          // to whatever the rest of the strip does (the drawer)
          if (facts.showBack)
            VrxPress(
              onTap: facts.onBack,
              child: SizedBox(
                width: 1.5 *
                    (ScaledSpacing.minInteractive(context) > Chrome.iconButton * VrxScale.of(context)
                        ? ScaledSpacing.minInteractive(context)
                        : Chrome.iconButton * VrxScale.of(context)),
                height: double.infinity,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Icon(VrxSymbols.arrow_back, size: Chrome.iconButton * VrxScale.of(context), color: colors.text),
                ),
              ),
            ),
          // the clock, and the day while there is room: all the width the
          // glyphs at the end leave (a fixed share cut "Tue 13 Oct" to
          // "Tue…" on the 43mm panel, beside an empty battery slot)
          Expanded(
            child: Row(children: [
              Text(
                facts.clockText ?? '--:--',
                style: TypeRole.of(context, VrxTypeRole.value),
              ),
              if (facts.dateText != null) ...[
                SizedBox(width: s.sm),
                Flexible(
                  child: VrxTruncates(
                    child: Text(
                      facts.dateText!,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: TypeRole.subtext(context).copyWith(color: colors.textSecondary),
                    ),
                  ),
                ),
              ],
            ]),
          ),
          // slot 3: wifi
          Icon(
            VrxSymbols.wifi,
            size: Chrome.statusButton,
            color: facts.wifiUp ? colors.text : colors.outlineFaint,
          ),
          // slot 4: ble — hidden when down, never a dead glyph
          if (facts.bleUp)
            Padding(
              padding: EdgeInsets.only(left: s.xs),
              child: Icon(
                VrxSymbols.bluetooth,
                size: Chrome.statusButton,
                color: colors.text,
              ),
            ),
          // the battery cell
          if (facts.batteryLevel != null) ...[
            SizedBox(width: s.sm),
            Icon(
              facts.batteryCharging
                  ? VrxSymbols.bolt
                  : _batteryGlyph(facts.batteryLevel!),
              size: Chrome.statusButton,
              color: colors.text,
            ),
            SizedBox(width: s.xs),
            Text(
              '${facts.batteryEstimated ? '~' : ''}${facts.batteryLevel}%',
              style: TypeRole.of(context, VrxTypeRole.value),
            ),
          ],
        ],
      ),
    );
  }

  /// Five levels: ≥88 full, ≥63, ≥38, ≥13, else empty.
  IconData _batteryGlyph(int level) {
    if (level >= 88) return VrxSymbols.battery_full;
    if (level >= 63) return VrxSymbols.battery_5_bar;
    if (level >= 38) return VrxSymbols.battery_3_bar;
    if (level >= 13) return VrxSymbols.battery_2_bar;
    return VrxSymbols.battery_0_bar;
  }
}
