/// The boot-flow screens, ported from evrx-rt's survey: the quick
/// drawer (the pull-down overlay) and the setup walk (first-boot's
/// "basic information" screens).
library;

import 'package:flutter/material.dart';

import 'components.dart';
import 'metrics.dart';
import 'scale.dart';
import 'slider.dart';
import 'symbols.dart';
import 'theme.dart';

/// The quick drawer: an overlay pulled from the top — an opaque scrim
/// (a tap dismisses it) and an opaque panel: the version row with power
/// at its right, the brightness slider (where the screen dims), and the
/// shortcut row (wifi, ble — filled when up) across the bottom with a
/// hairline above it. A shortcut closes the drawer before acting (a
/// drawer's answer is an effect, never a state it lingers to show); the
/// slider is the one control that stays, so the screen can be watched
/// as it dims. There is no light switch: the screen is never made dark
/// by hand (plan 0010 D1).
class VrxQuickDrawer extends StatelessWidget {
  const VrxQuickDrawer({
    super.key,
    required this.version,
    this.brightness,
    this.onBrightness,
    this.onBrightnessEnd,
    this.onPower,
    required this.wifiUp,
    required this.bleUp,
    this.onWifi,
    this.onBle,
    this.onDismiss,
  });

  final String version;

  /// The brightness slider's position (0 to 100); no slider when null
  /// (the screen does not dim).
  final int? brightness;
  final ValueChanged<int>? onBrightness;
  final ValueChanged<int>? onBrightnessEnd;
  /// The power menu (restart, power off): a CM4 does not suspend, so
  /// this is never sleep on vrx.
  final VoidCallback? onPower;
  final bool wifiUp;
  final bool bleUp;
  final VoidCallback? onWifi;
  final VoidCallback? onBle;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = VrxTheme.of(context);
    final s = ScaledSpacing.of(context);
    return Positioned.fill(
      child: Stack(children: [
        // the scrim: a tap dismisses. A sibling of the panel, so its words
        // ("Close the drawer", what a walk finds it by) stay its own
        Positioned.fill(
          child: Semantics(
            label: 'Close the drawer',
            button: true,
            child: GestureDetector(
              onTap: onDismiss,
              child: ColoredBox(color: colors.page.withValues(alpha: 0.6)),
            ),
          ),
        ),
        Align(
            alignment: Alignment.topCenter,
            child: GestureDetector(
              onTap: () {}, // the panel eats taps; they do not dismiss
              excludeFromSemantics: true,
              child: Container(
                width: double.infinity,
                // the drawer rests on the surface, as the strip it opens from
                color: colors.surface,
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
                          glyph: VrxSymbols.power_settings_new,
                          label: 'Power',
                          onTap: onPower,
                        ),
                      ],
                    ),
                    // the gutter between the power button and the slider
                    if (brightness != null) SizedBox(height: s.sm),
                    if (brightness != null)
                      Row(children: [
                        Icon(VrxSymbols.brightness_low, color: colors.text, size: VrxTypeRole.body.dp * VrxScale.of(context)),
                        Expanded(
                          child: VrxSlider(
                            label: 'Brightness',
                            value: brightness!,
                            onChanged: onBrightness,
                            onChangeEnd: onBrightnessEnd,
                          ),
                        ),
                        Icon(VrxSymbols.brightness_high, color: colors.text, size: VrxTypeRole.body.dp * VrxScale.of(context)),
                      ]),
                    SizedBox(height: s.sm),
                    Container(
                      decoration: BoxDecoration(
                        border: Border(
                          top: BorderSide(
                            color: colors.outline,
                            width: Strokes.hairline,
                          ),
                        ),
                      ),
                      padding: EdgeInsets.symmetric(vertical: s.md),
                      child: Row(
                        children: [
                          _Shortcut(
                            glyph: VrxSymbols.wifi,
                            label: 'Wi-Fi',
                            filled: wifiUp,
                            onTap: onWifi,
                          ),
                          SizedBox(width: s.sm),
                          _Shortcut(
                            glyph: VrxSymbols.bluetooth,
                            label: 'Bluetooth',
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
      ]),
    );
  }
}

class _Shortcut extends StatelessWidget {
  const _Shortcut({required this.glyph, required this.label, required this.filled, this.onTap});

  final IconData glyph;
  final String label;
  final bool filled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = VrxTheme.of(context);
    // a control: the touch minimum on a touch display, 4mm elsewhere
    final side = (Chrome.statusButton * VrxScale.of(context)).clamp(ScaledSpacing.minInteractive(context), double.infinity);
    return VrxPress(
      onTap: onTap,
      label: label,
      child: Container(
        width: side,
        height: side,
        decoration: BoxDecoration(
          color: filled ? colors.primary : null,
          border: Border.all(color: colors.outline, width: Strokes.hairline),
        ),
        child: Icon(
          glyph,
          size: side * 0.5,
          color: filled ? colors.onPrimary : colors.textSecondary,
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
          // the step's words and its control: spaced out on a screen with
          // room, scrolled on one without (the 58mm disp28a under the
          // shell's strip); Next stays put under them
          Expanded(
            child: VrxPaged(
              builder: (context, box) => ConstrainedBox(
                  constraints: BoxConstraints(minHeight: box.maxHeight),
                  child: IntrinsicHeight(
                    child: Column(
                      children: [
                        SizedBox(height: s.md),
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
                      ],
                    ),
                  ),
                ),
              ),
          ),
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

/// A screen body that pages when it is taller than the client (plan 0013
/// D9). The swipe chain is Flutter's gesture arena: a drag goes to the
/// innermost scrollable that claims it (a list, a wheel), then outwards;
/// a vertical drag nothing inside claims pages this body, a client height
/// at a time ([PageScrollPhysics] pages by the viewport on any scroll
/// position). A body that fits does not move. [builder] gets the client's
/// constraints, so a body can fill it when it fits.
class VrxPaged extends StatelessWidget {
  const VrxPaged({super.key, required this.builder});

  final Widget Function(BuildContext context, BoxConstraints client) builder;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) => SingleChildScrollView(
        physics: const PageScrollPhysics(),
        child: builder(context, box),
      ),
    );
  }
}
