import 'package:vrx_kit/vrx_kit.dart';

/// The walk, in evrx-rt's order. Nothing is written until the last step.
enum SetupStep { licence, name, wifi, zone, done }

enum SetupAction { init, moved, zonesLoaded, factsChanged, failed, again }

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

  /// Opened at [route]: `again` from Settings, anything else the first
  /// boot (an unknown route arrives as the root).
  void openedAt(String route) {
    again = route == 'again';
    if (again) step = SetupStep.licence;
  }

  /// Steps in order; the walk only moves forward and back by one.
  void next() {
    if (step.index < SetupStep.values.length - 1) step = SetupStep.values[step.index + 1];
  }

  void back() {
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
    if (action == SetupAction.moved) error = null;
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
}

class SetupState {
  const SetupState({required this.step});

  final SetupStep step;
}
