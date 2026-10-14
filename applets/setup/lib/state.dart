import 'package:vrx_kit/vrx_kit.dart';

/// The walk, in evrx-rt's order. Nothing is written until the last step.
enum SetupStep { licence, name, wifi, zone, done }

/// Everything Setup reacts to (plan 0013 D1: the reducer is the only
/// writer): a step, or a fact carried as data.
sealed class SetupAction {
  const SetupAction();

  static const init = SetupSignal.init;
  static const next = SetupSignal.next;
  static const back = SetupSignal.back;
}

enum SetupSignal implements SetupAction { init, next, back }

/// Opened at [route]: `again` from Settings, anything else the first boot
/// (an unknown route arrives as the root, plan 0011 D5).
final class SetupOpened implements SetupAction {
  const SetupOpened(this.route);

  final String route;
}

/// The name was typed; a blank one stays on its step and says why.
final class SetupName implements SetupAction {
  const SetupName(this.text);

  final String text;
}

/// A time zone was picked; the walk moves on.
final class SetupPickZone implements SetupAction {
  const SetupPickZone(this.zone);

  final String zone;
}

/// The network now, timedated's zone (taken only while none is picked),
/// the zone list, a refusal (null fields: unchanged).
final class SetupFacts implements SetupAction {
  const SetupFacts({this.network, this.zone, this.zones, this.error});

  final String? network;
  final String? zone;
  final List<String>? zones;
  final String? error;
}

/// The last step started writing ([done] false), or finished (true), or
/// failed ([error]).
final class SetupFinish implements SetupAction {
  const SetupFinish({required this.done, this.error});

  final bool done;
  final String? error;
}

class SetupView {
  const SetupView({
    required this.step,
    required this.name,
    required this.zone,
    required this.zones,
    required this.network,
    required this.error,
    required this.finishing,
    this.again = false,
  });

  final SetupStep step;
  final String name;
  final String zone;
  final List<String> zones;

  /// The network now (Wi-Fi joined or a cable), for the Wi-Fi step.
  final String network;
  final String? error;

  /// The last step is writing.
  final bool finishing;

  /// Opened from Settings to set the device up again (the `again` route):
  /// the end saves and goes back, instead of starting the device.
  final bool again;
}

class SetupModel extends StoreModel<SetupState, SetupAction, SetupView> {
  SetupStep step = SetupStep.licence;
  String name = '';
  String zone = '';
  List<String> zones = const [];
  String network = '';
  String? error;
  bool finishing = false;

  /// Set up again, from Settings (the `again` route).
  bool again = false;

  /// Steps in order; the walk only moves forward and back by one.
  void _next() {
    if (step.index < SetupStep.values.length - 1) step = SetupStep.values[step.index + 1];
  }

  void _back() {
    if (step.index > 0) step = SetupStep.values[step.index - 1];
  }

  /// A name is required: it is the device's name on the network.
  bool get canLeaveName => name.trim().isNotEmpty;

  @override
  SetupState get initial => SetupState(step: step);

  @override
  SetupAction get bootAction => SetupAction.init;

  @override
  SetupView reduce(SetupState state, SetupAction action) {
    switch (action) {
      case SetupOpened(:final route):
        again = route == 'again';
        if (again) step = SetupStep.licence;
        error = null;
      case SetupName(:final text):
        name = text;
        if (canLeaveName) {
          error = null;
          _next();
        } else {
          error = 'The device needs a name';
        }
      case SetupPickZone(zone: final z):
        zone = z;
        error = null;
        _next();
      case SetupFacts(network: final n, zone: final z, zones: final list, error: final err):
        if (n != null) network = n;
        if (z != null && zone.isEmpty) zone = z;
        if (list != null) zones = list;
        if (err != null) error = err;
      case SetupFinish(:final done, error: final err):
        finishing = !done && err == null;
        if (err != null) error = err;
      case SetupSignal.next:
        error = null;
        _next();
      case SetupSignal.back:
        error = null;
        _back();
      case SetupSignal.init:
        break;
    }
    return SetupView(
      step: step,
      name: name,
      zone: zone,
      zones: zones,
      network: network,
      error: error,
      finishing: finishing,
      again: again,
    );
  }

  @override
  SetupState get snapshot => SetupState(step: step);

  @override
  void restore(SetupState snapshot) => step = snapshot.step;

  @override
  SetupAction get backAction => SetupAction.back;

  @override
  bool get atRoot => step == SetupStep.licence;

  @override
  Object? get fingerprint => [step, name, zone, zones, network, error, finishing, again];
}

class SetupState {
  const SetupState({required this.step});

  final SetupStep step;

  @override
  bool operator ==(Object other) => other is SetupState && other.step == step;

  @override
  int get hashCode => step.hashCode;

  @override
  String toString() => 'SetupState($step)';
}
