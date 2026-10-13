import 'package:vrx_kit/vrx_kit.dart';

/// Everything Wi-Fi reacts to.
enum WifiAction {
  init,

  /// connman's state changed.
  networkChanged,

  /// The passphrase screen opened or closed.
  asked,

  /// A system call failed; the banner says why.
  failed,
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
}

/// The model: connman's state, the network being asked about, the error.
class WifiModel extends StoreModel<WifiState, WifiAction, WifiView> {
  NetworkState? network;
  WifiNetwork? asking;
  String? error;

  @override
  WifiState get initial => const WifiState();

  @override
  WifiAction get bootAction => WifiAction.init;

  @override
  WifiView reduce(WifiState state, WifiAction action) {
    if (action == WifiAction.asked) error = null;
    final n = network;
    final connected = n?.connected;
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
    );
  }

  @override
  WifiState get snapshot => const WifiState();
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
