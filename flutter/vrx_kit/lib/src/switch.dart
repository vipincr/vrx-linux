/// A screen change inside an applet (plan 0017 D6, micro.screen), and an
/// applet coming to the front (D8, micro.applet).
///
/// Applets swap a body inside one `home:`: no Navigator route, so no route
/// transition. [VrxSwitch] is the transition for that: when the model's
/// `screen` changes, the new screen slides in from the side by the standard's
/// 10 mm on the expressive spring while the old one leaves as a picture.
/// Deeper comes from the right, shallower from the left, an equal depth
/// cross-fades. The new screen is the live tree, laid out where it is and
/// painted through a transform, so a tap at half-way lands on the control as
/// it is drawn (D1), and nothing under motion is ignored.
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'metrics.dart';
import 'motion.dart';
import 'scale.dart';
import 'store.dart' show vrxDeepEquals;
import 'theme.dart';
import 'ui_standard.g.dart';

class VrxSwitch extends StatefulWidget {
  const VrxSwitch({super.key, required this.screen, required this.depth, required this.child});

  /// Which screen [child] is, by identity (`StoreModel.screen`).
  final Object screen;

  /// How deep it is (`StoreModel.depth`).
  final int depth;

  final Widget child;

  @override
  State<VrxSwitch> createState() => _VrxSwitchState();
}

class _VrxSwitchState extends State<VrxSwitch> with SingleTickerProviderStateMixin {
  // progress of the change, 0 to 1 (a little over while the spring bounces);
  // 48 px is the row's reference travel: the unit sets the tolerance
  late final VrxSpringValue _p = VrxSpringValue(vsync: this, value: 1, unit: VrxUnit.fractionOf(48));
  final _boundary = GlobalKey();
  ui.Image? _old;
  // +1: the new screen comes from the right, -1 from the left, 0 cross-fades
  int _dir = 0;
  VrxMotionMode _mode = VrxMotionMode.full;

  @override
  void initState() {
    super.initState();
    _p.addListener(_landed);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _mode = VrxMotion.of(context);
    _p.mode = _mode;
  }

  @override
  void didUpdateWidget(VrxSwitch old) {
    super.didUpdateWidget(old);
    if (vrxDeepEquals(widget.screen, old.screen)) return;
    // at still nothing moves: one paint of the new screen
    if (!_mode.springs && !_mode.fadesOnly) return;
    _dir = (widget.depth - old.depth).sign;
    _release();
    // the old screen's last frame, as a picture: the boundary still holds
    // the layer it painted (this frame has not painted yet)
    if (_mode.fades) {
      final boundary = _boundary.currentContext?.findRenderObject();
      if (boundary is RenderRepaintBoundary) {
        try {
          // the retained layer, as a GPU texture: no dart:io, nothing waits
          _old = boundary.toImageSync(pixelRatio: MediaQuery.devicePixelRatioOf(context)); // vrx-allow: a GPU snapshot, not dart:io
        } on Object catch (_) {
          // nothing to show leaving: the new screen arrives alone
        }
      }
    }
    _p.jumpTo(0);
    _p.springTo(1, VrxSpring.micro(VrxMicro.screen), fadeWhenReduced: true);
  }

  void _release() {
    _old?.dispose();
    _old = null;
  }

  // arrived: the picture of the old screen is let go
  void _landed() {
    if (_old != null && _p.value >= 1 && !_p.isAnimating) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _p.value >= 1) setState(_release);
      });
    }
  }

  @override
  void dispose() {
    _p.dispose();
    _release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shift = (vrxMicro[VrxMicro.screen]!.shiftMm ?? 0) * mmToDp * VrxScale.of(context);
    final colors = VrxTheme.of(context);
    return ListenableBuilder(
      listenable: _p,
      child: KeyedSubtree(key: _boundary, child: RepaintBoundary(child: widget.child)),
      builder: (context, child) {
        final p = _p.value;
        final slides = _mode.springs && _dir != 0;
        final dx = slides ? _dir * shift * (1 - p) : 0.0;
        final fades = _mode.fades && (_dir == 0 || _old != null || _mode.fadesOnly);
        final fadeIn = fades ? p.clamp(0.0, 1.0) : 1.0;
        return ColoredBox(
          color: colors.page,
          child: Stack(fit: StackFit.passthrough, children: [
            if (_old != null && p < 1)
              Positioned.fill(
                // the old screen is a picture: it takes no input
                child: IgnorePointer(
                  child: Opacity(
                    opacity: (1 - p).clamp(0.0, 1.0),
                    child: Transform.translate(
                      offset: Offset(slides ? -_dir * shift * p : 0, 0),
                      child: RawImage(image: _old, fit: BoxFit.fill),
                    ),
                  ),
                ),
              )
            else
              const SizedBox.shrink(),
            Opacity(opacity: fadeIn, child: Transform.translate(offset: Offset(dx, 0), child: child)),
          ]),
        );
      },
    );
  }
}

/// An applet coming to the front (plan 0017 D8, micro.applet): the page
/// colour is there from the first paint and the content rises the row's
/// `shift_px` with a fade at the full tier, slides without fading at light,
/// fades only with Reduce motion on, and is just there at still. A cold start
/// counts; so does the applet's return from behind another (lifecycle
/// `resumed` after `hidden`, which flutter-vrx drives from the compositor's
/// focus).
class VrxEntrance extends StatefulWidget {
  const VrxEntrance({super.key, required this.child});

  final Widget child;

  @override
  State<VrxEntrance> createState() => _VrxEntranceState();
}

class _VrxEntranceState extends State<VrxEntrance> with SingleTickerProviderStateMixin {
  late final VrxSpringValue _p = VrxSpringValue(vsync: this, value: 1, unit: VrxUnit.fractionOf(24));
  AppLifecycleListener? _lifecycle;
  // behind another since it was last in front
  bool _away = false;
  VrxMotionMode _mode = VrxMotionMode.full;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onStateChange: (s) {
      // inactive is a system sheet over it, not leaving; hidden is
      if (s == AppLifecycleState.hidden || s == AppLifecycleState.paused) _away = true;
      if (s == AppLifecycleState.resumed && _away) {
        _away = false;
        _enter();
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _mode = VrxMotion.of(context);
    _p.mode = _mode;
    if (!_started) {
      _started = true;
      _enter();
    }
  }

  void _enter() {
    if (!_mode.springs && !_mode.fadesOnly) return;
    // starting again while one runs is a retarget from 0, never a second animation
    _p.jumpTo(0);
    _p.springTo(1, VrxSpring.micro(VrxMicro.applet), fadeWhenReduced: true);
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    _p.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rise = vrxMicro[VrxMicro.applet]!.shiftPx ?? 0;
    final colors = VrxTheme.of(context);
    return ColoredBox(
      color: colors.page,
      child: ListenableBuilder(
        listenable: _p,
        child: widget.child,
        builder: (context, child) {
          final p = _p.value;
          final dy = _mode.springs ? (1 - p) * rise : 0.0;
          final a = _mode.fades ? p.clamp(0.0, 1.0) : 1.0;
          return Opacity(opacity: a, child: Transform.translate(offset: Offset(0, dy), child: child));
        },
      ),
    );
  }
}
