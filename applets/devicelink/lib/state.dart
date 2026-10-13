import 'package:vrx_kit/vrx_kit.dart';

/// Everything the applet reacts to.
enum LinkAction { init, factsChanged, failed, pairingOpened, pairingClosed, asked, answered, deviceOpened, deviceClosed }

/// Which screen is up.
enum LinkScreen { main, device, asking }

class LinkView {
  const LinkView({
    required this.screen,
    required this.status,
    this.present = false,
    this.allowed = true,
    this.on = false,
    this.pairing = false,
    this.pairDetail,
    this.devices = const [],
    this.device,
    this.askingName = '',
    this.passkey,
    this.error,
    this.notice,
  });

  final LinkScreen screen;

  /// One sentence on what Bluetooth is doing now.
  final String status;
  final bool present;
  final bool allowed;
  final bool on;

  /// Phones can find and pair with this device now.
  final bool pairing;

  /// "Visible to phones until 14:23".
  final String? pairDetail;
  final List<BluetoothDevice> devices;

  /// The paired device whose screen is open.
  final BluetoothDevice? device;

  /// The phone asking to pair, and the digits both screens show.
  final String askingName;
  final String? passkey;
  final String? error;
  final String? notice;

  /// Something can be done here: the radio exists and this applet may
  /// reach the adapter.
  bool get usable => present && allowed;
}

/// Device Link's model: BlueZ and connman's facts (BluetoothService), the
/// window this applet opened, and the request a phone made.
class LinkModel extends StoreModel<Object, LinkAction, LinkView> {
  LinkModel({int Function()? now}) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final int Function() _now;
  BluetoothState? bt;

  /// The phone asking now; answered through [answer].
  BluetoothPairing? asking;
  void Function(bool pair)? answer;

  /// When the window this applet opened closes (ms since the epoch).
  int? visibleUntil;

  /// The paired device whose screen is open (its BlueZ path).
  String? showing;

  /// 12 or 24 hours: the system's locale (plan 0011 D7).
  bool h24 = true;
  String? error;
  String? notice;

  /// The screen stays on while a passkey is up (it must be read against
  /// the phone's) and while phones can pair (the person is busy on the
  /// phone, not touching this screen): plan 0010 D3, a hold is state.
  @override
  String? get keepsScreenOn => asking != null
      ? 'a phone is asking to pair'
      : (bt?.discoverable ?? false)
          ? 'phones can pair with this device now'
          : null;

  @override
  Object get initial => const Object();

  @override
  LinkAction get bootAction => LinkAction.init;

  @override
  LinkView reduce(Object state, LinkAction action) {
    switch (action) {
      case LinkAction.factsChanged:
        error = null;
        // the window ended (timed out, or closed elsewhere)
        if (!(bt?.discoverable ?? false)) visibleUntil = null;
        // a forgotten device's screen has nothing to show
        if (showing != null && !(bt?.devices.any((d) => d.id == showing) ?? false)) showing = null;
      case LinkAction.pairingOpened:
        error = null;
        visibleUntil = _now() + BluetoothService.window.inMilliseconds;
      case LinkAction.pairingClosed:
        visibleUntil = null;
        notice = null;
      case LinkAction.answered:
        asking = null;
        answer = null;
      case LinkAction.deviceClosed:
        showing = null;
      case LinkAction.init || LinkAction.failed || LinkAction.asked || LinkAction.deviceOpened:
        break;
    }
    final b = bt;
    if (b == null) return const LinkView(screen: LinkScreen.main, status: '');
    final a = asking;
    if (a != null) {
      return LinkView(
        screen: LinkScreen.asking,
        status: a.passkey == null
            ? 'Pair only if you asked ${a.name} to pair just now.'
            : 'Pair only if ${a.name} shows the same number.',
        present: true,
        on: b.on,
        askingName: a.name,
        passkey: a.passkeyText,
        error: error,
      );
    }
    final device = showing == null ? null : b.devices.where((d) => d.id == showing).firstOrNull;
    final until = visibleUntil;
    String? detail;
    if (b.discoverable) {
      if (until == null) {
        detail = 'Visible to phones now';
      } else {
        final t = DateTime.fromMillisecondsSinceEpoch(until);
        detail = 'Visible to phones until ${VrxTimeFormat.hm(t.hour * 60 + t.minute, h24: h24)}';
      }
    }
    return LinkView(
      screen: device != null ? LinkScreen.device : LinkScreen.main,
      status: _status(b),
      present: b.present,
      allowed: b.allowed,
      on: b.on,
      pairing: b.discoverable,
      pairDetail: detail,
      devices: b.devices,
      device: device,
      error: error,
      notice: notice,
    );
  }

  static String _status(BluetoothState b) {
    if (!b.present) return 'This device has no Bluetooth.';
    if (!b.allowed) return VrxWords.notAllowed;
    if (!b.on) return 'Bluetooth is off. Pairing a phone turns it on.';
    if (b.discoverable) {
      return b.name.isEmpty
          ? 'On your phone, open its Bluetooth settings and choose this device.'
          : 'On your phone, open its Bluetooth settings and choose ${b.name}.';
    }
    final c = b.connected;
    if (c != null) return 'Connected to ${c.name}.';
    if (b.devices.isEmpty) return 'No phone is paired yet.';
    return b.devices.length == 1 ? 'One phone is paired.' : '${b.devices.length} phones are paired.';
  }

  @override
  Object get snapshot => const Object();
}
