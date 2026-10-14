import 'package:vrx_kit/vrx_kit.dart';

enum ShellAction { init, factsChanged, drawerToggled, powerAsked, powerDismissed }

class ShellView {
  const ShellView({
    required this.drawer,
    this.askingPower = false,
    required this.facts,
    required this.version,
    this.brightness,
    required this.wifiUp,
    this.bleUp = false,
    required this.canGoBack,
    this.alert,
  });

  /// The drawer is open (the shell asks for the whole screen).
  final bool drawer;

  /// The power question is up (restart, power off); the shell keeps the
  /// whole screen until it is answered.
  final bool askingPower;
  final VrxStatusFacts facts;
  final String version;

  /// The brightness slider's position; null where the screen does not dim.
  final int? brightness;
  final bool wifiUp;

  /// The Bluetooth radio is on (connman).
  final bool bleUp;
  final bool canGoBack;

  /// An applet over its power budget, waiting for the person (plan 0012
  /// D11): a band under the strip with Not now and Stop.
  final PowerAlert? alert;
}

/// The shell's model: facts from the services, the drawer's state.
class ShellModel extends StoreModel<ShellState, ShellAction, ShellView> {
  ShellModel({int Function()? now}) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final int Function() _now;
  bool drawer = false;
  bool askingPower = false;
  bool wifiUp = false;
  bool bleUp = false;

  /// How the compositor dims, and the brightness setting (plan 0010 D8).
  VrxDimming dimming = VrxDimming.none;
  int brightness = ScreenSettings.defaultBrightness;
  bool clockValid = false;
  String version = '';

  /// The back trail's depth (vrxhost), Home included: Back is offered
  /// above Home (the bench showed it on Home at depth > 0).
  int depth = 0;

  /// The battery, where the kernel reports one (plan 0011 D12).
  Battery? battery;

  /// "Recorder stopped.": said once in the strip, until the next
  /// navigation (plan 0011 D2).
  String? notice;

  /// 12 or 24 hours: the system's locale (plan 0011 D7).
  bool h24 = true;

  /// The power alerts vrxhost raised (plan 0012 D11); the first open one
  /// is shown.
  List<PowerAlert> alerts = const [];

  String get clockText {
    if (!clockValid) return '--:--';
    final t = DateTime.fromMillisecondsSinceEpoch(_now());
    return VrxTimeFormat.hm(t.hour * 60 + t.minute, h24: h24);
  }

  static const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  /// "Tue 13 Oct"; nothing while the clock is unset.
  String? get dateText {
    if (!clockValid) return null;
    final t = DateTime.fromMillisecondsSinceEpoch(_now());
    return '${_days[t.weekday - 1]} ${t.day} ${_months[t.month - 1]}';
  }

  @override
  ShellState get initial => const ShellState();

  @override
  ShellAction get bootAction => ShellAction.init;

  @override
  ShellView reduce(ShellState state, ShellAction action) {
    switch (action) {
      case ShellAction.drawerToggled:
        drawer = !drawer;
      case ShellAction.powerAsked:
        // the drawer closes before acting; the question takes its place
        drawer = false;
        askingPower = true;
      case ShellAction.powerDismissed:
        askingPower = false;
      case ShellAction.init || ShellAction.factsChanged:
        break;
    }
    return ShellView(
      drawer: drawer,
      askingPower: askingPower,
      facts: VrxStatusFacts(
        showBack: depth > 1,
        clockText: clockText,
        dateText: dateText,
        wifiUp: wifiUp,
        bleUp: bleUp,
        notice: notice,
        batteryLevel: battery?.percent,
        batteryCharging: battery?.charging ?? false,
      ),
      version: version,
      brightness: dimming == VrxDimming.none ? null : brightness,
      wifiUp: wifiUp,
      bleUp: bleUp,
      canGoBack: depth > 1,
      alert: alerts.where((a) => a.open).firstOrNull,
    );
  }

  @override
  ShellState get snapshot => const ShellState();
}

class ShellState {
  const ShellState();
}
