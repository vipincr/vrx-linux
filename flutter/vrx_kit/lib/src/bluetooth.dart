/// Bluetooth for Device Link (plan 0011 D19), Linux first: connman owns
/// the radio's power (its `bluetooth` technology, the same switch it
/// holds for Wi-Fi), BlueZ owns the adapter, the bonds and pairing. vrx
/// adds only what neither has: the applet's own pairing agent, which puts
/// the passkey on the screen and asks Pair or Cancel (BlueZ's
/// `DisplayYesNo`), and the window it is open for.
///
/// Reading the radio needs the `network` grant (connman); the adapter,
/// the paired phones and pairing need the `bluetooth` grant (vrx-policy's
/// bus policy keeps org.bluez to that group). Without it [BluetoothState]
/// still says whether the radio is on, and [BluetoothState.allowed] is
/// false.
library;

import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';

import 'system.dart';

/// A phone (or any device) paired with this one.
class BluetoothDevice {
  const BluetoothDevice({required this.id, required this.name, this.connected = false});

  /// BlueZ's object path (`/org/bluez/hci0/dev_AA_BB_...`).
  final String id;

  /// Its alias: the name it gave, or its address when it gave none.
  final String name;
  final bool connected;
}

/// The radio, the adapter and the paired devices.
class BluetoothState {
  const BluetoothState({
    required this.present,
    required this.on,
    this.allowed = true,
    this.discoverable = false,
    this.name = '',
    this.devices = const [],
  });

  /// connman has a Bluetooth radio on this device.
  final bool present;

  /// The radio is on (connman's `Powered`).
  final bool on;

  /// The adapter could be read (the `bluetooth` grant).
  final bool allowed;

  /// Phones nearby can find this device now (BlueZ `Discoverable`).
  final bool discoverable;

  /// What a phone lists this device as: the adapter's alias, which BlueZ
  /// takes from the device's name (systemd-hostnamed). '' when unknown.
  final String name;

  /// Paired devices, connected first.
  final List<BluetoothDevice> devices;

  BluetoothDevice? get connected {
    for (final d in devices) {
      if (d.connected) return d;
    }
    return null;
  }
}

/// A phone asking to pair, as BlueZ's agent call put it.
class BluetoothPairing {
  BluetoothPairing({required this.device, required this.name, this.passkey});

  final String device;
  final String name;

  /// The six digits both screens show (numeric comparison); null when the
  /// phone has no screen to compare with (BlueZ asks only yes or no).
  final int? passkey;

  final _canceled = Completer<void>();

  /// BlueZ gave up on the request (the phone canceled, or it timed out).
  Future<void> get canceled => _canceled.future;

  /// Give up on it: the agent's `Cancel` (and a stand-in service's).
  void cancel() {
    if (!_canceled.isCompleted) _canceled.complete();
  }

  /// "123 456", the way a phone shows it.
  String? get passkeyText {
    final p = passkey;
    if (p == null) return null;
    final s = p.toString().padLeft(6, '0');
    return '${s.substring(0, 3)} ${s.substring(3)}';
  }
}

abstract class BluetoothService {
  /// How long the pairing window stays open: BlueZ's own default
  /// `DiscoverableTimeout`, and long enough to find a setting on a phone.
  static const window = Duration(seconds: 180);

  Stream<BluetoothState> watch();

  /// Turn the radio on or off (connman).
  Future<void> setOn(bool on);

  /// Let phones find and pair with this device for [window]: the radio on
  /// first if it is off, this applet's agent registered, then BlueZ's
  /// `Pairable` and `Discoverable` with that timeout. [confirm] answers
  /// each request (true pairs).
  Future<void> openPairing({required Future<bool> Function(BluetoothPairing request) confirm});

  /// Close the window early, and stop answering requests.
  Future<void> closePairing();

  /// Forget a paired device (`Adapter1.RemoveDevice`): it has to pair
  /// again to connect.
  Future<void> forget(String device);
}

class LinuxBluetoothService implements BluetoothService {
  LinuxBluetoothService(this._bus)
      : _connman = DBusRemoteObject(_bus, name: 'net.connman', path: DBusObjectPath('/')),
        _technology = DBusRemoteObject(_bus, name: 'net.connman', path: DBusObjectPath('/net/connman/technology/bluetooth')),
        _bluez = DBusRemoteObject(_bus, name: 'org.bluez', path: DBusObjectPath('/'));

  final DBusClient _bus;
  final DBusRemoteObject _connman;
  final DBusRemoteObject _technology;
  final DBusRemoteObject _bluez;
  _PairingAgent? _agent;

  static const _adapterIface = 'org.bluez.Adapter1';
  static const _deviceIface = 'org.bluez.Device1';

  DBusRemoteObject _object(String path) => DBusRemoteObject(_bus, name: 'org.bluez', path: DBusObjectPath(path));

  Future<({bool present, bool on})> _radio() async {
    final techs = await _connman.callMethod('net.connman.Manager', 'GetTechnologies', const [],
        replySignature: DBusSignature('a(oa{sv})'));
    for (final t in techs.returnValues.first.asArray()) {
      final props = t.asStruct()[1].asStringVariantDict();
      if (props['Type']?.asString() == 'bluetooth') {
        return (present: true, on: props['Powered']?.asBoolean() ?? false);
      }
    }
    return (present: false, on: false);
  }

  /// The first adapter's path and properties, and the paired devices.
  Future<({String? adapter, Map<String, DBusValue> props, List<BluetoothDevice> devices})> _adapter() async {
    final objects = await _bluez.callMethod('org.freedesktop.DBus.ObjectManager', 'GetManagedObjects', const [],
        replySignature: DBusSignature('a{oa{sa{sv}}}'));
    String? adapter;
    var props = <String, DBusValue>{};
    final devices = <BluetoothDevice>[];
    for (final entry in objects.returnValues.first.asDict().entries) {
      final path = entry.key.asObjectPath().value;
      final ifaces = {
        for (final i in entry.value.asDict().entries) i.key.asString(): i.value.asStringVariantDict(),
      };
      final a = ifaces[_adapterIface];
      if (a != null && adapter == null) {
        adapter = path;
        props = a;
      }
      final d = ifaces[_deviceIface];
      if (d != null && (d['Paired']?.asBoolean() ?? false)) {
        devices.add(BluetoothDevice(
          id: path,
          name: d['Alias']?.asString() ?? d['Address']?.asString() ?? path.split('/').last,
          connected: d['Connected']?.asBoolean() ?? false,
        ));
      }
    }
    devices.sort((a, b) {
      if (a.connected != b.connected) return a.connected ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return (adapter: adapter, props: props, devices: devices);
  }

  Future<BluetoothState> _read() async {
    final radio = await _radio();
    if (!radio.present) return const BluetoothState(present: false, on: false);
    try {
      final a = await _adapter();
      return BluetoothState(
        present: true,
        on: radio.on,
        discoverable: radio.on && (a.props['Discoverable']?.asBoolean() ?? false),
        name: a.props['Alias']?.asString() ?? '',
        devices: a.devices,
      );
    } on DBusMethodResponseException catch (err) {
      final denied = SystemError(err.errorName, '').denied;
      // no bluetooth grant (the shell): the radio is all this applet sees
      if (denied) return BluetoothState(present: true, on: radio.on, allowed: false);
      // bluetoothd not running: the radio's switch is still connman's
      if (err.errorName.endsWith('ServiceUnknown') || err.errorName.endsWith('NameHasNoOwner')) {
        return BluetoothState(present: true, on: radio.on);
      }
      rethrow;
    }
  }

  @override
  Stream<BluetoothState> watch() {
    late StreamController<BluetoothState> out;
    final subscriptions = <StreamSubscription<Object?>>[];
    Future<void> read() async {
      try {
        out.add(await _read());
      } on DBusMethodResponseException catch (err) {
        out.addError(SystemError(err.errorName, '${err.response.values.firstOrNull?.toNative() ?? ''}'));
      } on Object catch (err) {
        out.addError(err);
      }
    }

    out = StreamController<BluetoothState>(
      onListen: () {
        subscriptions
          // the radio's switch (connman)
          ..add(DBusSignalStream(_bus, sender: 'net.connman', interface: 'net.connman.Technology', name: 'PropertyChanged')
              .listen((_) => unawaited(read())))
          ..add(DBusRemoteObjectSignalStream(object: _connman, interface: 'net.connman.Manager', name: 'TechnologyAdded')
              .listen((_) => unawaited(read())))
          ..add(DBusRemoteObjectSignalStream(object: _connman, interface: 'net.connman.Manager', name: 'TechnologyRemoved')
              .listen((_) => unawaited(read())))
          // the adapter and the devices (BlueZ): a device paired, forgotten,
          // connected; the window opened or timed out
          ..add(DBusSignalStream(_bus,
                  sender: 'org.bluez', interface: 'org.freedesktop.DBus.ObjectManager', name: 'InterfacesAdded')
              .listen((_) => unawaited(read())))
          ..add(DBusSignalStream(_bus,
                  sender: 'org.bluez', interface: 'org.freedesktop.DBus.ObjectManager', name: 'InterfacesRemoved')
              .listen((_) => unawaited(read())))
          ..add(DBusSignalStream(_bus, sender: 'org.bluez', interface: 'org.freedesktop.DBus.Properties', name: 'PropertiesChanged')
              .listen((_) => unawaited(read())))
          ..add(_bus.nameOwnerChanged
              .where((e) => (e.name == 'net.connman' || e.name == 'org.bluez') && e.newOwner != null)
              .listen((_) => unawaited(read())));
        unawaited(read());
      },
      onCancel: () async {
        for (final s in subscriptions) {
          await s.cancel();
        }
        await out.close();
      },
    );
    return out.stream;
  }

  @override
  Future<void> setOn(bool on) => _call(() => _technology.callMethod(
      'net.connman.Technology', 'SetProperty', [const DBusString('Powered'), DBusVariant(DBusBoolean(on))],
      replySignature: DBusSignature('')));

  /// The adapter's path once its radio is on: connman unblocks it, and
  /// BlueZ powers it a moment later.
  Future<String> _poweredAdapter() async {
    for (var i = 0; i < 25; i++) {
      final a = await _adapter();
      final path = a.adapter;
      if (path != null && (a.props['Powered']?.asBoolean() ?? false)) return path;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    throw const SystemError('org.bluez.Error.NotReady', 'the adapter did not power on');
  }

  @override
  Future<void> openPairing({required Future<bool> Function(BluetoothPairing request) confirm}) => _call(() async {
        if (!(await _radio()).on) await setOn(true);
        final adapter = await _poweredAdapter();
        final agent = _agent ??= _PairingAgent(DBusObjectPath('/io/vrx/bluez/agent$pid'), _bus);
        agent.confirm = confirm;
        if (!agent.registered) {
          await _bus.registerObject(agent);
          final manager = _object('/org/bluez');
          await manager.callMethod('org.bluez.AgentManager1', 'RegisterAgent',
              [agent.path, const DBusString('DisplayYesNo')], replySignature: DBusSignature(''));
          await manager.callMethod('org.bluez.AgentManager1', 'RequestDefaultAgent', [agent.path],
              replySignature: DBusSignature(''));
          agent.registered = true;
        }
        final seconds = DBusUint32(BluetoothService.window.inSeconds);
        final a = _object(adapter);
        Future<void> set(String name, DBusValue value) => a.setProperty(_adapterIface, name, value);
        await set('PairableTimeout', seconds);
        await set('DiscoverableTimeout', seconds);
        await set('Pairable', const DBusBoolean(true));
        await set('Discoverable', const DBusBoolean(true));
      });

  @override
  Future<void> closePairing() => _call(() async {
        final a = await _adapter();
        final path = a.adapter;
        if (path != null && (a.props['Powered']?.asBoolean() ?? false)) {
          final adapter = _object(path);
          await adapter.setProperty(_adapterIface, 'Discoverable', const DBusBoolean(false));
          await adapter.setProperty(_adapterIface, 'Pairable', const DBusBoolean(false));
        }
        final agent = _agent;
        if (agent != null && agent.registered) {
          agent.registered = false;
          agent.confirm = null;
          try {
            await _object('/org/bluez').callMethod('org.bluez.AgentManager1', 'UnregisterAgent', [agent.path],
                replySignature: DBusSignature(''));
          } on DBusMethodResponseException catch (_) {
            // bluetoothd restarted and forgot it already
          }
          await _bus.unregisterObject(agent);
        }
      });

  @override
  Future<void> forget(String device) => _call(() async {
        final a = await _adapter();
        final path = a.adapter;
        if (path == null) throw const SystemError('org.bluez.Error.NotReady', 'no adapter');
        await _object(path).callMethod(_adapterIface, 'RemoveDevice', [DBusObjectPath(device)],
            replySignature: DBusSignature(''));
      });
}

Future<T> _call<T>(Future<T> Function() body) async {
  try {
    return await body();
  } on DBusMethodResponseException catch (err) {
    throw SystemError(err.errorName, err.response.values.isEmpty ? '' : '${err.response.values.first.toNative()}');
  }
}

/// BlueZ's agent for the window: numeric comparison and yes/no requests
/// go to the applet; nothing is typed here (DisplayYesNo has no keyboard
/// in BlueZ's sense). A paired device's service connections are allowed;
/// an unpaired one's are not.
class _PairingAgent extends DBusObject {
  _PairingAgent(super.path, this._bus);

  final DBusClient _bus;
  Future<bool> Function(BluetoothPairing request)? confirm;
  bool registered = false;
  BluetoothPairing? _pending;

  static const _rejected = 'org.bluez.Error.Rejected';

  DBusRemoteObject _device(DBusObjectPath path) => DBusRemoteObject(_bus, name: 'org.bluez', path: path);

  Future<String> _name(DBusObjectPath device) async {
    try {
      return (await _device(device).getProperty('org.bluez.Device1', 'Alias', signature: DBusSignature('s'))).asString();
    } on DBusMethodResponseException catch (_) {
      return device.value.split('/').last.replaceFirst('dev_', '').replaceAll('_', ':');
    }
  }

  Future<DBusMethodResponse> _ask(DBusObjectPath device, int? passkey) async {
    final ask = confirm;
    if (ask == null) return DBusMethodErrorResponse(_rejected);
    final request = BluetoothPairing(device: device.value, name: await _name(device), passkey: passkey);
    _pending = request;
    try {
      if (!await ask(request)) return DBusMethodErrorResponse(_rejected);
      // trusted: the phone reconnects later without this agent asking
      // again (the applet is not running then)
      await _device(device).setProperty('org.bluez.Device1', 'Trusted', const DBusBoolean(true));
      return DBusMethodSuccessResponse();
    } finally {
      _pending = null;
    }
  }

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    if (call.interface != 'org.bluez.Agent1') return DBusMethodErrorResponse.unknownInterface();
    switch (call.name) {
      case 'RequestConfirmation':
        return _ask(call.values[0].asObjectPath(), call.values[1].asUint32());
      case 'RequestAuthorization':
        return _ask(call.values[0].asObjectPath(), null);
      case 'AuthorizeService':
        try {
          final paired = (await _device(call.values[0].asObjectPath())
                  .getProperty('org.bluez.Device1', 'Paired', signature: DBusSignature('b')))
              .asBoolean();
          return paired ? DBusMethodSuccessResponse() : DBusMethodErrorResponse(_rejected);
        } on DBusMethodResponseException catch (_) {
          return DBusMethodErrorResponse(_rejected);
        }
      case 'RequestPinCode':
      case 'RequestPasskey':
        return DBusMethodErrorResponse(_rejected);
      case 'DisplayPinCode':
      case 'DisplayPasskey':
      case 'Release':
        return DBusMethodSuccessResponse();
      case 'Cancel':
        _pending?.cancel();
        return DBusMethodSuccessResponse();
      default:
        return DBusMethodErrorResponse.unknownMethod();
    }
  }
}
