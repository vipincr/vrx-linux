/// The motion engine (plan 0017 D2): every spring in vrx runs through here.
///
/// The vocabulary is the UI standard's `[springs.*]` and `[micro.*]` rows plus
/// vrx's overlay (`standard/vrx-motion.toml`), generated into
/// `ui_standard.g.dart`; a component names a [VrxMicro] row and this file turns
/// it into a Flutter `SpringSimulation` with a tolerance in pixels (D3), runs it
/// on one `AnimationController`, and applies the build's tier and the Reduce
/// motion row (D5). Components and applets never touch an
/// `AnimationController`, a `Curve`, an `Animated*` widget or a
/// `ScrollPhysics`: G050 refuses them everywhere but here.
///
/// Spatial tokens may overshoot (position, size, rotation); effects tokens are
/// critically damped (colour, opacity): a colour refuses a spatial spring.
/// Things that travel use the expressive set and bounce; controls that change
/// in place use the standard set and are crisp (D13), per the overlay's `[set]`.
library;

import 'dart:async';

import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import 'ui_standard.g.dart';

// --- tokens ---------------------------------------------------------------------------------------------------

/// One spring of one set: a token of `[springs.standard]` or
/// `[springs.expressive]` at mass 1.
class VrxSpring {
  const VrxSpring(this.set, this.token);

  /// A micro row's own token, from the set the overlay's `[set]` gives it.
  /// A component asks for the row and never picks a spring.
  VrxSpring.micro(VrxMicro row, {bool follow = false})
      : set = vrxMicro[row]!.set,
        token = follow ? vrxMicro[row]!.follow : vrxMicro[row]!.token;

  final VrxSpringSet set;
  final VrxSpringToken token;

  SpringDescription get description {
    final row = vrxSprings[set]![token]!;
    return SpringDescription(mass: vrxSpringMass, stiffness: row.stiffness, damping: row.damping);
  }

  /// Effects springs (colour, opacity) are critically damped; a spatial one
  /// may overshoot.
  bool get isEffects =>
      token == VrxSpringToken.effects || token == VrxSpringToken.effectsFast || token == VrxSpringToken.effectsSlow;

  @override
  bool operator ==(Object other) => other is VrxSpring && other.set == set && other.token == token;

  @override
  int get hashCode => Object.hash(set, token);

  @override
  String toString() => 'VrxSpring(${set.name}, ${token.name})';
}

/// What one unit of a controller's value is, which decides its tolerance
/// (plan 0017 D3): half a device pixel and 5 px/s for a position, one 8-bit
/// step for an opacity, and the same pixels over the element's size for a
/// unit-less fraction (a scale). There is no way to build a simulation
/// without saying so.
class VrxUnit {
  const VrxUnit._(this.distance, this.velocity);

  /// A value in logical pixels; [devicePixelRatio] makes the tolerance half
  /// a *device* pixel.
  factory VrxUnit.px({double devicePixelRatio = 1}) {
    assert(devicePixelRatio > 0);
    return VrxUnit._(vrxToleranceDistancePx / devicePixelRatio, vrxToleranceVelocityPxPerS / devicePixelRatio);
  }

  /// A fraction of an element that is [px] pixels long (1.0 is all of it).
  factory VrxUnit.fractionOf(double px, {double devicePixelRatio = 1}) {
    assert(px > 0 && devicePixelRatio > 0);
    return VrxUnit._(
        vrxToleranceDistancePx / devicePixelRatio / px, vrxToleranceVelocityPxPerS / devicePixelRatio / px);
  }

  /// An opacity from 0 to 1.
  static const VrxUnit alpha = VrxUnit._(vrxToleranceAlphaStep, vrxToleranceAlphaVelocity);

  final double distance;
  final double velocity;

  Tolerance get tolerance => Tolerance(distance: distance, velocity: velocity);
}

/// The one constructor of a `SpringSimulation` (G050): [spring] from [from] to
/// [to] carrying [velocity], done when within [unit]'s tolerance, and landing
/// exactly on [to] when it is.
SpringSimulation vrxSimulate(VrxSpring spring, double from, double to, double velocity, VrxUnit unit) =>
    SpringSimulation(spring.description, from, to, velocity, snapToEnd: true, tolerance: unit.tolerance);

/// When [spring] first comes within a tenth of [travel] of its target, and
/// when it is within [unit]'s tolerance for good, in milliseconds. What
/// G051's ceiling test measures, and what the wheel helper sizes its
/// duration with.
({double arriveMs, double settleMs}) vrxMeasure(VrxSpring spring, double travel, VrxUnit unit) {
  final sim = vrxSimulate(spring, 0, travel, 0, unit);
  double? arrive;
  var settle = 0.0;
  const stepMs = 0.25;
  for (var t = 0.0; t < 5000; t += stepMs) {
    final x = sim.x(t / 1000);
    final dx = sim.dx(t / 1000);
    if (arrive == null && (travel - x).abs() <= 0.1 * travel.abs()) arrive = t;
    if ((travel - x).abs() > unit.distance || dx.abs() > unit.velocity) settle = t + stepMs;
    if (arrive != null && sim.isDone(t / 1000)) break;
  }
  return (arriveMs: arrive ?? settle, settleMs: settle);
}

// --- the tier -------------------------------------------------------------------------------------------------

/// What this build and this person allow to move (plan 0017 D5). The build's
/// [tier] comes from the display class or `VRX_UI_MOTION`; Reduce motion
/// ([reduced], Flutter's `MediaQuery.disableAnimations`) only ever takes
/// motion away on top of it.
class VrxMotionMode {
  const VrxMotionMode(this.tier, {this.reduced = false});

  /// Everything in the table, nobody asking for less.
  static const VrxMotionMode full = VrxMotionMode(VrxTier.full);

  final VrxTier tier;
  final bool reduced;

  /// Springs run. At still, and with Reduce motion on, every travel lands at
  /// once.
  bool get springs => tier != VrxTier.still && !reduced;

  /// Reduce motion on a build that moves: a screen change or an entrance is
  /// a quick cross-fade instead of a slide.
  bool get fadesOnly => reduced && tier != VrxTier.still;

  /// Nothing moves: one paint of the final state.
  bool get still => tier == VrxTier.still;

  /// A screen change or an entrance fades: at full, and on a reduced build
  /// (which fades and does nothing else). Light slides without fading.
  bool get fades => (tier == VrxTier.full && !reduced) || fadesOnly;

  /// Rows enter staggered: the full tier's.
  bool get staggers => tier == VrxTier.full && !reduced;

  /// A scale of [permille] (970 is a press, 1300 a key's preview) animates:
  /// never at still or reduced, at light only up to the overlay's limit.
  bool allowsScale(int permille) {
    if (!springs) return false;
    if (tier == VrxTier.light) return (permille - 1000).abs() <= vrxLightScaleLimitPermille;
    return true;
  }

  @override
  bool operator ==(Object other) => other is VrxMotionMode && other.tier == tier && other.reduced == reduced;

  @override
  int get hashCode => Object.hash(tier, reduced);

  @override
  String toString() => 'VrxMotionMode(${tier.name}${reduced ? ', reduced' : ''})';
}

/// The build's tier for this subtree, read once at boot (`AppletHost`); a
/// tree with none is the full tier.
class VrxMotionScope extends InheritedWidget {
  const VrxMotionScope({super.key, required this.tier, required super.child});

  final VrxTier tier;

  @override
  bool updateShouldNotify(VrxMotionScope old) => old.tier != tier;
}

abstract final class VrxMotion {
  /// The mode this context moves in: the build's tier and the Reduce motion
  /// row (G053: this is the one reader of Flutter's `disableAnimations`).
  static VrxMotionMode of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<VrxMotionScope>();
    return VrxMotionMode(scope?.tier ?? VrxTier.full, reduced: MediaQuery.maybeDisableAnimationsOf(context) ?? false);
  }

  /// The tier a boot has: `/usr/lib/vrx/motion-tier` ([text]) over the
  /// display class's own (G053: the one parse of it). Anything absent or not
  /// a tier is the class's.
  static VrxTier tierFrom(String text, VrxDisplayClass cls) =>
      vrxTierNames[text.trim()] ?? vrxTierOfClass[cls] ?? VrxTier.full;
}

// --- the spring value -----------------------------------------------------------------------------------------

/// A number that springs to its target: one `AnimationController.unbounded`
/// behind a `ChangeNotifier`. A new target retargets from the current value
/// and velocity (plan 0017 D1: input always lands mid-animation, and a
/// retarget keeps the motion's momentum). At the still tier, or with Reduce
/// motion on, the value jumps and no ticker ever runs.
class VrxSpringValue extends ChangeNotifier {
  VrxSpringValue({
    required TickerProvider vsync,
    required double value,
    required this.unit,
    VrxMotionMode mode = VrxMotionMode.full,
  })  : _mode = mode,
        _target = value {
    _c = AnimationController.unbounded(vsync: vsync, value: value)..addListener(notifyListeners);
  }

  late final AnimationController _c;
  final VrxUnit unit;
  VrxMotionMode _mode;
  double _target;

  VrxMotionMode get mode => _mode;

  /// The mode a build and a person allow, set from `didChangeDependencies`.
  /// Taking springs away mid-flight lands the value on its target.
  set mode(VrxMotionMode m) {
    if (m == _mode) return;
    _mode = m;
    if (!m.springs && _c.isAnimating) jumpTo(_target);
  }

  double get value => _c.value;

  /// Units per second; 0 at rest.
  double get velocity => _c.isAnimating ? _c.velocity : 0;

  bool get isAnimating => _c.isAnimating;

  /// Where the running spring is going (the value, at rest).
  double get target => _target;

  /// Spring to [target] on [spring], from where it is and with the velocity
  /// it has (or [velocity], a fling's).
  void springTo(double target, VrxSpring spring, {double? velocity}) {
    _target = target;
    if (!_mode.springs) {
      _c.stop();
      _setValue(target);
      return;
    }
    final v = velocity ?? this.velocity;
    // an exact arrival is not an animation
    if (value == target && v == 0) {
      _c.stop();
      return;
    }
    unawaited(_c.animateWith(vrxSimulate(spring, _c.value, target, v, unit)).orCancel.then((_) {}, onError: (Object _) {}));
  }

  /// Set the value now (a finger dragging, a restored state), cancelling any
  /// spring.
  void jumpTo(double value) {
    _c.stop();
    _target = value;
    _setValue(value);
  }

  void _setValue(double v) {
    if (_c.value != v) _c.value = v;
  }

  /// Hold where it is.
  void stop() {
    _c.stop();
    _target = _c.value;
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }
}

/// Springs [value] to a new target whenever it changes, and hands the
/// animated number to [builder]. [from] starts the first arrival away from
/// the target (an entrance); without it the first build is at rest.
class VrxSpringBuilder extends StatefulWidget {
  const VrxSpringBuilder({
    super.key,
    required this.value,
    required this.spring,
    required this.unit,
    required this.builder,
    this.from,
    this.child,
  });

  final double value;
  final VrxSpring spring;
  final VrxUnit unit;
  final double? from;
  final Widget? child;
  final Widget Function(BuildContext context, double value, Widget? child) builder;

  @override
  State<VrxSpringBuilder> createState() => _VrxSpringBuilderState();
}

class _VrxSpringBuilderState extends State<VrxSpringBuilder> with SingleTickerProviderStateMixin {
  late final VrxSpringValue _v = VrxSpringValue(vsync: this, value: widget.from ?? widget.value, unit: widget.unit);
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _v.mode = VrxMotion.of(context);
    if (!_started) {
      _started = true;
      if (widget.from != null) _v.springTo(widget.value, widget.spring);
    }
  }

  @override
  void didUpdateWidget(VrxSpringBuilder old) {
    super.didUpdateWidget(old);
    if (widget.value != old.value) _v.springTo(widget.value, widget.spring);
  }

  @override
  void dispose() {
    _v.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: _v,
        child: widget.child,
        builder: (context, child) => widget.builder(context, _v.value, child),
      );
}

// --- routes and scrolling ---------------------------------------------------------------------------------

/// A route's progress that jumps to its end at once: the still tier's.
class _Landed extends Simulation {
  _Landed(this.at);

  final double at;

  @override
  double x(double time) => at;

  @override
  double dx(double time) => 0;

  @override
  bool isDone(double time) => true;
}

/// The simulation a `TransitionRoute.createSimulation` returns (plan 0017
/// D2): [row]'s spring from the controller's [from] and [velocity] to [rest]
/// (a push) or 0 (a pop). The controller is bounded at 1, so [rest] sits
/// below it: an overshoot of up to 9.5 % of the way has room to show.
Simulation vrxRouteSimulation({
  required VrxMotionMode mode,
  required VrxMicro row,
  required bool forward,
  required double from,
  required double velocity,
  required double travelPx,
  double rest = 0.85,
}) {
  final to = forward ? rest : 0.0;
  if (mode.still) return _Landed(to);
  // Reduce motion: the cross-fade of the standard's quickest effects spring
  final spring = mode.springs ? VrxSpring.micro(row) : const VrxSpring(VrxSpringSet.standard, VrxSpringToken.effectsFast);
  return vrxSimulate(spring, from, to, velocity, VrxUnit.fractionOf(travelPx / rest));
}

/// The progress of a route that [vrxRouteSimulation] drives, as 0 to 1 and a
/// little over while it overshoots.
double vrxRouteProgress(double value, {double rest = 0.85}) => value / rest;

/// A `Curve` that remaps a route's raw value to [vrxRouteProgress]'s, clamped
/// to 0..1: what a modal barrier fades with.
class VrxRouteCurve extends Curve {
  const VrxRouteCurve({this.rest = 0.85});

  final double rest;

  @override
  double transformInternal(double t) => (t / rest).clamp(0.0, 1.0);
}

/// A spring as a `Curve`, for the one framework call that takes a duration
/// and a curve (`animateToItem`): the simulation from 0 to 1, stretched over
/// the time it takes to settle. It overshoots, as the spring does.
class VrxSpringCurve extends Curve {
  factory VrxSpringCurve(VrxSpring spring, double travelPx) {
    final unit = VrxUnit.fractionOf(travelPx);
    final sim = vrxSimulate(spring, 0, 1, 0, unit);
    final settleMs = vrxMeasure(spring, 1, unit).settleMs;
    return VrxSpringCurve._(sim, settleMs / 1000);
  }

  // not const: the simulation is built at run time
  // ignore: prefer_const_constructors_in_immutables
  VrxSpringCurve._(this._sim, this.seconds);

  final SpringSimulation _sim;

  /// How long the spring takes to settle.
  final double seconds;

  Duration get duration => Duration(microseconds: (seconds * Duration.microsecondsPerSecond).ceil());

  @override
  double transformInternal(double t) => _sim.x(t * seconds);
}

/// Turn a wheel to [item] on the wheel row's spring; at still, or with
/// Reduce motion on, it lands at once. [itemExtent] is the row's height in
/// pixels.
Future<void> vrxTurnWheel(
  FixedExtentScrollController controller,
  int item, {
  required double itemExtent,
  required VrxMotionMode mode,
}) {
  if (!mode.springs) {
    controller.jumpToItem(item);
    return Future<void>.value();
  }
  final distance = (item - controller.selectedItem).abs() * itemExtent;
  if (distance == 0) return Future<void>.value();
  final curve = VrxSpringCurve(VrxSpring.micro(VrxMicro.wheel), distance);
  return controller.animateToItem(item, duration: curve.duration, curve: curve);
}

/// The one scroll physics (plan 0017 D10): a list past its end travels with
/// the friction of Flutter's own `BouncingScrollPhysics` and returns on the
/// overscroll row's spring; a fling is Flutter's own friction simulation.
/// `VrxScrollBehavior` installs it for every scrollable in a kit or applet;
/// at still, or with Reduce motion on, a scrollable clamps instead.
class VrxScrollPhysics extends BouncingScrollPhysics {
  const VrxScrollPhysics({super.parent});

  @override
  VrxScrollPhysics applyTo(ScrollPhysics? ancestor) => VrxScrollPhysics(parent: buildParent(ancestor));

  @override
  SpringDescription get spring => VrxSpring.micro(VrxMicro.overscroll).description;

  /// The physics a scrollable under [context] has: this one, or clamping
  /// where nothing springs.
  static ScrollPhysics of(BuildContext context) =>
      VrxMotion.of(context).springs ? const VrxScrollPhysics() : const ClampingScrollPhysics();
}

/// A page snap and a wheel detent settle on the same spring as the end of a
/// list: they take the behaviour's physics as their parent through
/// `applyTo`.
const ScrollPhysics vrxPagedPhysics = PageScrollPhysics();
const ScrollPhysics vrxWheelPhysics = FixedExtentScrollPhysics();

/// How far a finger [overscroll] pixels past a stop moves what it drags:
/// Flutter's own `BouncingScrollPhysics.frictionFactor`, so the drawer's
/// rubber band and a list's agree. [extent] is the length it travels over.
double vrxRubberBand(double overscroll, double extent) {
  if (overscroll <= 0) return 0;
  const bouncing = BouncingScrollPhysics();
  final fraction = (overscroll / extent).clamp(0.0, 1.0);
  return bouncing.frictionFactor(fraction) * overscroll;
}

/// Scrolling on vrx: no scrollbar drawn over the content (Flutter's
/// desktop default on Linux painted one across Home's tiles), and a mouse
/// or touchpad drags a list as a finger does; the wheel scrolls too.
class VrxScrollBehavior extends MaterialScrollBehavior {
  const VrxScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.stylus,
      };

  @override
  Widget buildScrollbar(BuildContext context, Widget child, ScrollableDetails details) => child;

  // one physics for every scrollable (plan 0017 D10): the end of a list
  // bounces on the overscroll row's spring, clamping where nothing springs
  @override
  ScrollPhysics getScrollPhysics(BuildContext context) => VrxScrollPhysics.of(context);
}
