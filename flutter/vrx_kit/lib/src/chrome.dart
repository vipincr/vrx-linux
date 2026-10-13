/// The status strip: the shell's chrome across the top — the host
/// applet's whole screen in evrx-rt, ported as the kit's chrome
/// widget. Facts in, glyphs out: the strip's owner passes WHAT is
/// true (clock set, wifi up, battery level) and this widget draws
/// the observation; it never decides policy (a low battery draws no
/// warning triangle here — that glyph belongs to whoever owns the
/// policy).
///
/// Seven equal slots (the evrx-rt contract): 0 back, 1-2 the clock,
/// 3 wifi, 4 ble (hidden when down — an always-present glyph says
/// nothing), 5-6 the battery cell (glyph + percent, `~` while
/// estimated). Hairline under; edge insets; the strip height is the
/// 4mm control + 2×1mm breathing room.
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

  @override
  Widget build(BuildContext context) {
    final palette = VrxTheme.of(context);
    final s = ScaledSpacing.of(context);
    return Container(
      // evrx-rt's 6mm strip, but never under the touch minimum on a
      // touch display: its Back is a control (the layout check found it
      // at 4mm on every touch panel); the hairline under it is extra
      height: (Chrome.statusHeight * VrxScale.of(context))
          .clamp(ScaledSpacing.minInteractive(context) + Strokes.hairline, double.infinity),
      // no breathing room above and below a touch-height strip: it would
      // squeeze the Back control under the minimum again
      padding: EdgeInsets.symmetric(
        horizontal: s.inset,
        vertical: ScaledSpacing.minInteractive(context) > 0 ? 0 : s.xs,
      ),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: palette.line, width: Strokes.hairline),
        ),
      ),
      child: Row(
        children: [
          // slot 0: back (offered, not asserted)
          if (facts.showBack)
            VrxIconButton(glyph: VrxSymbols.arrow_back, onTap: facts.onBack),
          // slots 1-2: the clock
          Expanded(
            flex: 2,
            child: Text(
              facts.clockText ?? '--:--',
              style: TypeRole.of(context, VrxTypeRole.value),
            ),
          ),
          // slot 3: wifi
          Icon(
            VrxSymbols.wifi,
            size: Chrome.statusButton,
            color: facts.wifiUp ? palette.text : palette.faint,
          ),
          // slot 4: ble — hidden when down, never a dead glyph
          if (facts.bleUp)
            Padding(
              padding: EdgeInsets.only(left: s.xs),
              child: Icon(
                VrxSymbols.bluetooth,
                size: Chrome.statusButton,
                color: palette.text,
              ),
            ),
          const Spacer(),
          // slots 5-6: the battery cell
          if (facts.batteryLevel != null) ...[
            Icon(
              facts.batteryCharging
                  ? VrxSymbols.bolt
                  : _batteryGlyph(facts.batteryLevel!),
              size: Chrome.statusButton,
              color: palette.text,
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
