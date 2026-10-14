import 'package:vrx_kit/vrx_kit.dart';

/// Everything the applet reacts to.
/// Everything the applet reacts to (plan 0013 D1: the reducer is the only
/// writer): a signal, or a fact from the world carried as data.
sealed class LinkAction {
  const LinkAction();

  static const init = LinkSignal.init;
  static const pairingOpened = LinkSignal.pairingOpened;
  static const pairingClosed = LinkSignal.pairingClosed;
  static const answered = LinkSignal.answered;
  static const deviceClosed = LinkSignal.deviceClosed;
}

enum LinkSignal implements LinkAction { init, pairingOpened, pairingClosed, answered, deviceClosed }

/// BlueZ and connman's state, the locale's hours, a refusal, a notice
/// (null fields: unchanged; Change(null) clears).
final class LinkFacts implements LinkAction {
  const LinkFacts({this.bt, this.h24, this.error, this.notice});

  final BluetoothState? bt;
  final bool? h24;
  final Change<String?>? error;
  final Change<String?>? notice;

  @override
  String toString() => 'LinkFacts($bt, $h24, $error, $notice)';
}

/// A phone asked to pair; [answer] settles BlueZ's question.
final class LinkAsked implements LinkAction {
  const LinkAsked(this.request, this.answer);

  final BluetoothPairing request;
  final void Function(bool pair) answer;
}

/// A paired device's screen was opened.
final class LinkOpenDevice implements LinkAction {
  const LinkOpenDevice(this.id);

  final String id;
}

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

  /// The facts are BlueZ's, read again at every start; nothing is kept.
  @override
  void restore(Object snapshot) {}

  @override
  LinkAction get backAction => LinkAction.deviceClosed;

  /// A phone's question is answered, never backed out of; a device's
  /// screen is closed by Back.
  @override
  bool get atRoot => showing == null;

  // the list, or one device's screen
  @override
  Object get screen => showing ?? 0;

  @override
  Object? get fingerprint => [bt?.on, bt?.discoverable, bt?.homePairing, bt?.devices.map((d) => d.id).toList(), asking?.name,
      visibleUntil, showing, h24, error, notice];

  @override
  LinkAction get bootAction => LinkAction.init;

  @override
  LinkView reduce(Object state, LinkAction action) {
    switch (action) {
      case LinkFacts(bt: final b, :final h24, error: final err, notice: final note):
        if (h24 != null) this.h24 = h24;
        if (b != null) {
          bt = b;
          error = null;
          // the window ended (timed out, or closed elsewhere)
          if (!b.discoverable) visibleUntil = null;
          // a forgotten device's screen has nothing to show
          if (showing != null && !b.devices.any((d) => d.id == showing)) showing = null;
        }
        if (err != null) error = err.value;
        if (note != null) notice = note.value;
      case LinkAsked(:final request, :final answer):
        asking = request;
        this.answer = answer;
      case LinkOpenDevice(:final id):
        showing = id;
      case LinkSignal.pairingOpened:
        error = null;
        visibleUntil = _now() + BluetoothService.window.inMilliseconds;
      case LinkSignal.pairingClosed:
        visibleUntil = null;
        notice = null;
      case LinkSignal.answered:
        asking = null;
        answer = null;
      case LinkSignal.deviceClosed:
        showing = null;
      case LinkSignal.init:
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
    // vrxhost's arbiter lent the radio to a home app (plan 0015 D4)
    if (b.homePairing) return 'A home app is pairing over Bluetooth. Pairing a phone waits until it is done.';
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
