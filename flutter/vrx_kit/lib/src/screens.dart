/// The boot-flow screens, ported from evrx-rt's survey: the quick
/// drawer (the pull-down overlay) and the setup walk (first-boot's
/// "basic information" screens).
library;

import 'package:flutter/material.dart';

import 'components.dart';
import 'metrics.dart';
import 'scale.dart';
import 'symbols.dart';
import 'theme.dart';

/// The quick drawer: an overlay pulled from the top — an opaque scrim
/// (a tap dismisses it) and an opaque panel: the version row, the
/// light toggle and sleep at its right, and the shortcut row (wifi,
/// ble — filled when up) across the bottom with a hairline above it.
/// Every control closes the drawer before acting (a drawer's answer
/// is an effect, never a state it lingers to show).
class VrxQuickDrawer extends StatelessWidget {
  const VrxQuickDrawer({
    super.key,
    required this.version,
    required this.lightOn,
    this.onLightToggle,
    this.onSleep,
    required this.wifiUp,
    required this.bleUp,
    this.onWifi,
    this.onBle,
    this.onDismiss,
  });

  final String version;
  final bool lightOn;
  final VoidCallback? onLightToggle;
  final VoidCallback? onSleep;
  final bool wifiUp;
  final bool bleUp;
  final VoidCallback? onWifi;
  final VoidCallback? onBle;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final palette = VrxTheme.of(context);
    final s = ScaledSpacing.of(context);
    return Positioned.fill(
      child: GestureDetector(
        // the scrim: a tap dismisses
        onTap: onDismiss,
        child: ColoredBox(
          color: palette.page.withValues(alpha: 0.6),
          child: Align(
            alignment: Alignment.topCenter,
            child: GestureDetector(
              onTap: () {}, // the panel eats taps; they do not dismiss
              child: Container(
                width: double.infinity,
                color: palette.page,
                padding: EdgeInsets.fromLTRB(s.md, s.md, s.md, 0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            version,
                            style: TypeRole.of(context, VrxTypeRole.subtext),
                          ),
                        ),
                        VrxIconButton(
                          glyph: lightOn ? VrxSymbols.light_mode : VrxSymbols.dark_mode,
                          onTap: onLightToggle,
                        ),
                        SizedBox(width: s.xs),
                        VrxIconButton(
                          glyph: VrxSymbols.power_settings_new,
                          onTap: onSleep,
                        ),
                      ],
                    ),
                    SizedBox(height: s.sm),
                    Container(
                      decoration: BoxDecoration(
                        border: Border(
                          top: BorderSide(
                            color: palette.line,
                            width: Strokes.hairline,
                          ),
                        ),
                      ),
                      padding: EdgeInsets.symmetric(vertical: s.md),
                      child: Row(
                        children: [
                          _Shortcut(
                            glyph: VrxSymbols.wifi,
                            filled: wifiUp,
                            onTap: onWifi,
                          ),
                          SizedBox(width: s.sm),
                          _Shortcut(
                            glyph: VrxSymbols.bluetooth,
                            filled: bleUp,
                            onTap: onBle,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Shortcut extends StatelessWidget {
  const _Shortcut({required this.glyph, required this.filled, this.onTap});

  final IconData glyph;
  final bool filled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final palette = VrxTheme.of(context);
    // a control: the touch minimum on a touch display, 4mm elsewhere
    final side = (Chrome.statusButton * VrxScale.of(context)).clamp(ScaledSpacing.minInteractive(context), double.infinity);
    return VrxPress(
      onTap: onTap,
      child: Container(
        width: side,
        height: side,
        decoration: BoxDecoration(
          color: filled ? palette.fill : null,
          border: Border.all(color: palette.line, width: Strokes.hairline),
        ),
        child: Icon(
          glyph,
          size: side * 0.5,
          color: filled ? palette.onFill : palette.secondary,
        ),
      ),
    );
  }
}

/// One setup step: the step caption ("Step N of M"), the centred
/// title, a fixed-line intro (exactly n lines — the figure below
/// keeps its height), the one control this step offers, and the
/// bottom Next button that fills the width.
class VrxSetupStep extends StatelessWidget {
  const VrxSetupStep({
    super.key,
    required this.step,
    required this.of,
    required this.title,
    required this.intro,
    required this.control,
    required this.onNext,
    this.nextLabel = 'Next',
    this.banner,
  });

  final int step;
  final int of;
  final String title;
  final String intro;
  final Widget control;

  /// The label of the advancing action; the last step says Finish.
  final String nextLabel;
  final VoidCallback? onNext;
  final String? banner;

  @override
  Widget build(BuildContext context) {
    final s = ScaledSpacing.of(context);
    return SafeArea(
      child: Column(
        children: [
          SizedBox(height: s.xl),
          Text(
            'Step $step of $of',
            style: TypeRole.of(context, VrxTypeRole.caption),
          ),
          SizedBox(height: s.sm),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TypeRole.of(context, VrxTypeRole.title),
          ),
          SizedBox(height: s.md),
          Text(
            intro,
            textAlign: TextAlign.center,
            style: TypeRole.of(context, VrxTypeRole.caption),
          ),
          const Spacer(),
          control,
          const Spacer(),
          if (banner != null) ...[
            VrxBanner(text: banner),
            SizedBox(height: s.sm),
          ],
          Padding(
            padding: EdgeInsets.all(s.md),
            child: SizedBox(
              width: double.infinity,
              child: VrxChip(
                label: nextLabel,
                filled: true,
                onTap: onNext,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
