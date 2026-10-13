import 'dart:math';

import 'package:vrx_kit/vrx_kit.dart';

enum ManageAction { init, factsChanged, failed, hosting }

class ManageView {
  const ManageView({
    required this.serving,
    required this.addresses,
    this.error,
    this.stoppedIdle = false,
    this.hosting = false,
    this.ssid = '',
    this.passphrase = '',
    this.onNoNetwork = false,
  });

  /// null until the first reading.
  final bool? serving;

  /// Where a browser finds the page: an address first (a phone may not
  /// resolve .local), then the name.
  final List<String> addresses;
  final String? error;

  /// It stopped by itself after ten minutes nobody asked.
  final bool stoppedIdle;

  /// The device hosts its own Wi-Fi network for a phone to join.
  final bool hosting;
  final String ssid;
  final String passphrase;

  /// No network to serve on, and none hosted.
  final bool onNoNetwork;

  /// The QR code a phone joins the hosted network with.
  String get wifiQr => 'WIFI:T:WPA;S:${_escape(ssid)};P:${_escape(passphrase)};;';
}

String _escape(String s) => s.replaceAllMapped(RegExp(r'[\;,:"]'), (m) => '\\${m[0]}');

/// The hosted network's name: `vrx-` and the hostname, within Wi-Fi's 32 bytes.
String hostedName(String hostname) {
  final n = 'vrx-${hostname.isEmpty ? 'device' : hostname}';
  return n.length > 32 ? n.substring(0, 32) : n;
}

/// A fresh passphrase for one session: 12 characters with nothing a
/// person reads wrong (no 0/O, 1/l/I).
String hostedPassphrase([Random? random]) {
  const alphabet = 'abcdefghjkmnpqrstuvwxyz23456789';
  final r = random ?? Random.secure();
  return [for (var i = 0; i < 12; i++) alphabet[r.nextInt(alphabet.length)]].join();
}

/// The model: serving or not (vrx-manage.service), the device's name and
/// addresses, the network it hosts, the last refusal.
class ManageModel extends StoreModel<bool, ManageAction, ManageView> {
  bool? serving;
  String hostname = '';
  List<String> ips = const [];
  String? error;

  /// This applet asked for the page to stop (leaving, or Stop): any other
  /// stop is vrx-manage's own after ten idle minutes.
  bool askedStop = false;
  bool stoppedIdle = false;

  bool hosting = false;
  String ssid = '';
  String passphrase = '';

  /// The hosted network's own address (connman's tether bridge).
  String hostedAddress = '';

  /// What serving changed to; a stop nobody asked for is the idle stop.
  void servingNow(bool on) {
    if (serving == true && !on && !askedStop) stoppedIdle = true;
    if (on) {
      stoppedIdle = false;
      askedStop = false;
    }
    serving = on;
  }

  @override
  bool get initial => false;

  @override
  ManageAction get bootAction => ManageAction.init;

  /// The page is served and in front: it must be seen to be found (its
  /// address and QR code), and the screen going off would hide the applet
  /// and stop the page under a browser using it.
  @override
  String? get keepsScreenOn => serving == true ? 'the management page is being served' : null;

  @override
  ManageView reduce(bool state, ManageAction action) {
    if (action == ManageAction.factsChanged) error = null;
    final linked = [for (final ip in ips) if (ip.isNotEmpty) ip];
    return ManageView(
      serving: serving,
      addresses: [
        if (hosting && hostedAddress.isNotEmpty) 'http://$hostedAddress',
        for (final ip in linked) 'http://$ip',
        if (hostname.isNotEmpty) 'http://$hostname.local',
      ],
      error: error,
      stoppedIdle: stoppedIdle,
      hosting: hosting,
      ssid: ssid,
      passphrase: passphrase,
      onNoNetwork: linked.isEmpty && !hosting,
    );
  }

  @override
  bool get snapshot => serving ?? false;
}
