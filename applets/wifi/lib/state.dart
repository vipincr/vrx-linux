import 'package:vrx_kit/vrx_kit.dart';

/// Everything Wi-Fi reacts to (plan 0013 D1: the reducer is the only
/// writer): a signal, or a fact carried as data.
sealed class WifiAction {
  const WifiAction();

  static const init = WifiSignal.init;
  static const joinEnded = WifiSignal.joinEnded;
  static const back = WifiSignal.back;
}

enum WifiSignal implements WifiAction { init, joinEnded, back }

/// connman's state, or a refusal (null fields: unchanged).
final class WifiFacts implements WifiAction {
  const WifiFacts({this.network, this.error});

  final NetworkState? network;
  final Change<String?>? error;
}

/// The passphrase screen opened for a network, or closed (null).
final class WifiAsk implements WifiAction {
  const WifiAsk(this.network);

  final WifiNetwork? network;
}

/// A network's own screen opened (connman's id), or closed (null).
final class WifiShow implements WifiAction {
  const WifiShow(this.id);

  final String? id;
}

/// A join of this network (connman's id) started.
final class WifiJoinStarted implements WifiAction {
  const WifiJoinStarted(this.id);

  final String id;
}

/// What Wi-Fi draws.
class WifiView {
  const WifiView({
    required this.present,
    required this.on,
    required this.connected,
    required this.nearby,
    required this.asking,
    required this.error,
    this.joining,
    this.showing,
  });

  /// The device has Wi-Fi.
  final bool present;
  final bool on;
  /// The joined network; its own address is connected.address.
  final WifiNetwork? connected;

  /// Everything else in range, strongest first.
  final List<WifiNetwork> nearby;

  /// The network the passphrase screen is for, or null.
  final WifiNetwork? asking;
  final String? error;

  /// The network being joined (connman's id): a second tap waits.
  final String? joining;

  /// The network whose own screen is open (its state as connman says
  /// now), or null.
  final WifiNetwork? showing;
}

/// The model: connman's state, the network being asked about, the error.
class WifiModel extends StoreModel<WifiState, WifiAction, WifiView> {
  NetworkState? network;
  WifiNetwork? asking;
  String? error;

  /// connman's id of the network being joined, or null.
  String? joining;

  /// connman's id of the network whose screen is open, or null.
  String? showing;

  /// [n] may be joined now: no other join is in flight and [n] is not
  /// already joining or joined (a second tap is not a second join).
  bool canJoin(WifiNetwork n) => joining == null && !n.connecting && !n.connected;

  @override
  WifiState get initial => const WifiState();

  @override
  WifiAction get bootAction => WifiAction.init;

  @override
  WifiView reduce(WifiState state, WifiAction action) {
    switch (action) {
      case WifiFacts(network: final n, error: final err):
        if (n != null) network = n;
        if (err != null) error = err.value;
      case WifiAsk(network: final n):
        asking = n;
        error = null;
      case WifiShow(:final id):
        showing = id;
        error = null;
      case WifiJoinStarted(:final id):
        joining = id;
      case WifiSignal.joinEnded:
        joining = null;
      case WifiSignal.back:
        showing = null;
      case WifiSignal.init:
        break;
    }
    final n = network;
    final connected = n?.connected;
    final all = n?.networks ?? const <WifiNetwork>[];
    final shown = [for (final w in all) if (w.id == showing) w];
    // a network that left range closes its screen
    if (shown.isEmpty) showing = null;
    return WifiView(
      present: n?.wifiPresent ?? true,
      on: n?.wifiOn ?? false,
      connected: connected,
      nearby: [
        for (final w in n?.networks ?? const <WifiNetwork>[])
          if (!w.connected) w,
      ],
      asking: asking,
      error: error,
      joining: joining,
      showing: shown.isEmpty ? null : shown.first,
    );
  }

  @override
  WifiState get snapshot => const WifiState();

  /// connman's state is read again at every start; nothing is kept.
  @override
  void restore(WifiState snapshot) {}

  @override
  WifiAction get backAction => WifiAction.back;

  /// The passphrase screen is answered (connman's agent waits on it),
  /// never backed out of here; a network's screen is closed by Back.
  @override
  bool get atRoot => showing == null;

  // the networks, one network's screen, or the passphrase being asked
  @override
  Object get screen => [showing, asking?.id];

  @override
  int get depth => asking != null || showing != null ? 1 : 0;

  @override
  Object? get fingerprint => [network?.networks.map((n) => '${n.id}/${n.state}').toList(), network?.wifiOn,
      asking?.id, error, joining, showing];
}

/// Nothing to keep across suspension: connman remembers networks.
class WifiState {
  const WifiState();
}

/// The signal glyph for a strength (VrxSymbols names).
String signalGlyph(int strength) {
  if (strength >= 75) return 'signal_wifi_4_bar';
  if (strength >= 50) return 'network_wifi_3_bar';
  if (strength >= 25) return 'network_wifi_2_bar';
  return 'network_wifi_1_bar';
}
