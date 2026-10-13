import 'package:vrx_kit/vrx_kit.dart';

enum ShellAction { init, factsChanged, drawerToggled, powerAsked, powerDismissed }

class ShellView {
  const ShellView({
    required this.drawer,
    this.askingPower = false,
    required this.facts,
    required this.version,
    required this.lightOn,
    required this.wifiUp,
    required this.canGoBack,
  });

  /// The drawer is open (the shell asks for the whole screen).
  final bool drawer;

  /// The power question is up (restart, power off); the shell keeps the
  /// whole screen until it is answered.
  final bool askingPower;
  final VrxStatusFacts facts;
  final String version;
  final bool lightOn;
  final bool wifiUp;
  final bool canGoBack;
}

/// The shell's model: facts from the services, the drawer's state.
class ShellModel extends StoreModel<ShellState, ShellAction, ShellView> {
  ShellModel({int Function()? now}) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final int Function() _now;
  bool drawer = false;
  bool askingPower = false;
  bool wifiUp = false;
  bool lightOn = true;
  bool clockValid = false;
  String version = '';

  /// The back trail's depth (vrxhost), Home included: Back is offered
  /// above Home (the bench showed it on Home at depth > 0).
  int depth = 0;

  String get clockText {
    if (!clockValid) return '--:--';
    final t = DateTime.fromMillisecondsSinceEpoch(_now());
    return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
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
      facts: VrxStatusFacts(showBack: depth > 1, clockText: clockText, dateText: dateText, wifiUp: wifiUp),
      version: version,
      lightOn: lightOn,
      wifiUp: wifiUp,
      canGoBack: depth > 1,
    );
  }

  @override
  ShellState get snapshot => const ShellState();
}

class ShellState {
  const ShellState();
}
