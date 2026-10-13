import 'package:vrx_kit/vrx_kit.dart';

enum ShellAction { init, factsChanged, drawerToggled }

class ShellView {
  const ShellView({
    required this.drawer,
    required this.facts,
    required this.version,
    required this.lightOn,
    required this.wifiUp,
    required this.canGoBack,
  });

  /// The drawer is open (the shell asks for the whole screen).
  final bool drawer;
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
  bool wifiUp = false;
  bool lightOn = true;
  bool clockValid = false;
  String version = '';

  /// The back trail's depth (vrxhost): Back is offered above Home.
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
    if (action == ShellAction.drawerToggled) drawer = !drawer;
    return ShellView(
      drawer: drawer,
      facts: VrxStatusFacts(showBack: depth > 0, clockText: clockText, dateText: dateText, wifiUp: wifiUp),
      version: version,
      lightOn: lightOn,
      wifiUp: wifiUp,
      canGoBack: depth > 0,
    );
  }

  @override
  ShellState get snapshot => const ShellState();
}

class ShellState {
  const ShellState();
}
