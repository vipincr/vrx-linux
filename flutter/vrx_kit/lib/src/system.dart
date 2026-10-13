/// The system, from an applet (plan 0008 D3): domain services an applet
/// codes against, never a transport. Each is implemented today over the
/// Linux service that owns the job, on D-Bus (Canonical's `dbus` package);
/// a domain moves to Varlink by swapping its implementation, with no
/// applet change. Live state is the service's own properties: a watcher
/// sees every change, and re-reads when the service restarts (a new name
/// owner), so it never shows a value a dead service left behind.
///
/// Authority is the service's: a call the applet's grants do not cover
/// fails with the service's own refusal ([SystemError]).
library;

import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';

/// A system call the service refused or could not do: its error name
/// (`org.freedesktop.DBus.Error.AccessDenied`, ...) and message.
class SystemError implements Exception {
  const SystemError(this.name, this.message);

  final String name;
  final String message;

  /// The service refused for lack of authority (no grant).
  bool get denied =>
      name.endsWith('AccessDenied') || name.endsWith('InteractiveAuthorizationRequired');

  @override
  String toString() => 'SystemError($name: $message)';
}

// ── time ──────────────────────────────────────────────────────────────

/// What the clock says about itself.
class TimeState {
  const TimeState({
    required this.zone,
    required this.automatic,
    required this.synced,
  });

  /// The IANA zone (`Asia/Kolkata`).
  final String zone;

  /// Network time is on (systemd-timesyncd).
  final bool automatic;

  /// The clock has synchronised with a time server.
  final bool synced;
}

/// Time zone, network time, setting the time. Needs the `time` grant
/// for anything but reading.
abstract class TimeService {
  Stream<TimeState> watch();
  Future<void> setZone(String zone);
  Future<void> setAutomatic(bool on);
  Future<void> setTime(DateTime time);
  Future<List<String>> zones();
}

// ── device ────────────────────────────────────────────────────────────

/// What the device is called and what it is. Each fact from where Linux
/// keeps it: the names from hostnamed, the rest from files the kernel
/// and the image already publish.
class DeviceState {
  const DeviceState({
    required this.name,
    required this.hostname,
    this.version = '',
    this.model = '',
    this.serial = '',
    this.memoryMb = 0,
  });

  /// The name a person gave it (pretty hostname), or the hostname.
  final String name;

  /// The network name (static hostname), derived from [name].
  final String hostname;

  /// The vrx release (/etc/os-release VERSION: `0.1.0074 (cm4-bcm2711)`).
  final String version;

  /// The board (/proc/device-tree/model).
  final String model;

  /// The board's serial (/proc/device-tree/serial-number).
  final String serial;

  /// Installed memory (/proc/meminfo MemTotal).
  final int memoryMb;
}

/// The device's name. Needs the `hostname` grant to change it.
abstract class DeviceService {
  Stream<DeviceState> watch();

  /// Set the name a person reads; the network name is derived from it.
  Future<void> setName(String name);
}

/// The network name for a person's name: lower case, letters, digits and
/// hyphens, no leading or trailing hyphen, at most 63 characters.
String hostnameFor(String name) {
  final slug = name
      .toLowerCase()
      .replaceAll(RegExp('[^a-z0-9]+'), '-')
      .replaceAll(RegExp('^-+|-+\$'), '');
  final cut = slug.length > 63 ? slug.substring(0, 63) : slug;
  return cut.isEmpty ? 'vrx' : cut.replaceAll(RegExp(r'-+$'), '');
}

// ── power and light ───────────────────────────────────────────────────

/// Power off, restart, and the display light. Needs the `power` grant
/// (logind) and the `display` grant (the backlight).
abstract class PowerService {
  /// Whether this applet may power off (logind's answer, without acting).
  Future<bool> canPowerOff();
  Future<void> powerOff();
  Future<void> reboot();

  /// The light: on/off now and on every change.
  Stream<bool> watchLight();
  Future<void> setLight(bool on);

  /// How many brightness levels the panel has; 2 means on/off only.
  Future<int> lightLevels();

  /// The supply: true while it is below what the board needs (the Pi's
  /// rpi_volt alarm), false while it is fine; nothing on a board without
  /// a supply sensor. Now and on every change.
  Stream<bool> watchSupplyLow();
}

// ── network ───────────────────────────────────────────────────────────

/// One network connman knows: in range, saved, or both.
class WifiNetwork {
  const WifiNetwork({
    required this.id,
    required this.name,
    required this.strength,
    required this.secured,
    required this.state,
    required this.saved,
    this.address = '',
  });

  /// connman's service path: what connect/forget take.
  final String id;
  final String name;

  /// 0-100.
  final int strength;
  final bool secured;

  /// idle, association, configuration, ready, online, disconnect, failure.
  final String state;

  /// connman remembers it (it joins on its own when in range).
  final bool saved;

  /// This network's own IPv4 address while connected, else ''.
  final String address;

  bool get connected => state == 'ready' || state == 'online';
  bool get connecting => state == 'association' || state == 'configuration';
}

/// The network as connman sees it.
class NetworkState {
  const NetworkState({
    required this.wifiPresent,
    required this.wifiOn,
    required this.networks,
    required this.ethernet,
    this.ethernetAddress = '',
  });

  /// The device has Wi-Fi at all (plan 0008 D12).
  final bool wifiPresent;
  final bool wifiOn;

  /// Wi-Fi networks, strongest first; the connected one first of all.
  final List<WifiNetwork> networks;

  /// The wired link's state ('' when there is no wired link).
  final String ethernet;

  /// The wired link's own IPv4 address while it is up, else ''. Each link
  /// carries its own address: with a cable and Wi-Fi both up there is no
  /// single "the address" (the bench showed the wired one on the Wi-Fi
  /// screen).
  final String ethernetAddress;

  bool get wired => ethernet == 'ready' || ethernet == 'online';

  WifiNetwork? get connected {
    for (final n in networks) {
      if (n.connected) return n;
    }
    return null;
  }
}

/// Wi-Fi and the wired link. Needs the `network` grant.
abstract class NetworkService {
  Stream<NetworkState> watch();
  Future<void> setWifi(bool on);
  Future<void> scan();

  /// Join a network. connman asks for a passphrase when it needs one;
  /// [passphrase] is called then, and null cancels the join.
  Future<void> connect(String id, {Future<String?> Function(String network)? passphrase});
  Future<void> disconnect(String id);

  /// Forget a saved network (connman drops its passphrase).
  Future<void> forget(String id);
}

/// connman over D-Bus. connman keeps its own property protocol
/// (GetProperties, PropertyChanged, Manager.ServicesChanged) rather than
/// org.freedesktop.DBus.Properties, and asks for passphrases through an
/// agent object the client exports (net.connman.Agent).
class ConnmanNetworkService implements NetworkService {
  ConnmanNetworkService(this._bus)
      : _manager = DBusRemoteObject(_bus, name: 'net.connman', path: DBusObjectPath('/'));

  final DBusClient _bus;
  final DBusRemoteObject _manager;
  _ConnmanAgent? _agent;

  static const _mgr = 'net.connman.Manager';

  DBusRemoteObject _object(String path) =>
      DBusRemoteObject(_bus, name: 'net.connman', path: DBusObjectPath(path));

  Future<NetworkState> _read() async {
    final techs = await _manager.callMethod(_mgr, 'GetTechnologies', const [],
        replySignature: DBusSignature('a(oa{sv})'));
    var wifiPresent = false, wifiOn = false;
    for (final t in techs.returnValues.first.asArray()) {
      final props = t.asStruct()[1].asStringVariantDict();
      if (props['Type']?.asString() == 'wifi') {
        wifiPresent = true;
        wifiOn = props['Powered']?.asBoolean() ?? false;
      }
    }
    final services = await _manager.callMethod(_mgr, 'GetServices', const [],
        replySignature: DBusSignature('a(oa{sv})'));
    final networks = <WifiNetwork>[];
    var ethernet = '', ethernetAddress = '';
    for (final entry in services.returnValues.first.asArray()) {
      final fields = entry.asStruct();
      final path = fields[0].asObjectPath().value;
      final p = fields[1].asStringVariantDict();
      final state = p['State']?.asString() ?? 'idle';
      final up = state == 'ready' || state == 'online';
      final address = up ? (p['IPv4']?.asStringVariantDict()['Address']?.asString() ?? '') : '';
      switch (p['Type']?.asString()) {
        case 'ethernet':
          ethernet = state;
          ethernetAddress = address;
        case 'wifi':
          final name = p['Name']?.asString() ?? '';
          if (name.isEmpty) continue; // a hidden network: not listed
          final security = p['Security']?.asStringArray().toList() ?? const [];
          networks.add(WifiNetwork(
            id: path,
            name: name,
            strength: (p['Strength']?.toNative() as int?) ?? 0,
            secured: security.any((s) => s != 'none'),
            state: state,
            saved: p['Favorite']?.asBoolean() ?? false,
            address: address,
          ));
      }
    }
    networks.sort((a, b) {
      if (a.connected != b.connected) return a.connected ? -1 : 1;
      return b.strength.compareTo(a.strength);
    });
    return NetworkState(
      wifiPresent: wifiPresent,
      wifiOn: wifiOn,
      networks: networks,
      ethernet: ethernet,
      ethernetAddress: ethernetAddress,
    );
  }

  @override
  Stream<NetworkState> watch() {
    late StreamController<NetworkState> out;
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

    out = StreamController<NetworkState>(
      onListen: () {
        for (final signal in ['ServicesChanged', 'TechnologyAdded', 'TechnologyRemoved', 'PropertyChanged']) {
          subscriptions.add(
              DBusRemoteObjectSignalStream(object: _manager, interface: _mgr, name: signal)
                  .listen((_) => unawaited(read())));
        }
        // a service's own state (association, ready) and a technology's
        // Powered arrive as PropertyChanged on their own objects
        subscriptions
          ..add(DBusSignalStream(_bus, sender: 'net.connman', interface: 'net.connman.Service', name: 'PropertyChanged')
              .listen((_) => unawaited(read())))
          ..add(DBusSignalStream(_bus, sender: 'net.connman', interface: 'net.connman.Technology', name: 'PropertyChanged')
              .listen((_) => unawaited(read())))
          ..add(_bus.nameOwnerChanged
              .where((e) => e.name == 'net.connman' && e.newOwner != null)
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
  Future<void> setWifi(bool on) => _call(() => _object('/net/connman/technology/wifi').callMethod(
      'net.connman.Technology', 'SetProperty', [const DBusString('Powered'), DBusVariant(DBusBoolean(on))],
      replySignature: DBusSignature('')));

  @override
  Future<void> scan() => _call(() => _object('/net/connman/technology/wifi')
      .callMethod('net.connman.Technology', 'Scan', const [], replySignature: DBusSignature('')));

  @override
  Future<void> connect(String id, {Future<String?> Function(String network)? passphrase}) => _call(() async {
        final agent = await _ensureAgent();
        agent.pending = passphrase;
        try {
          await _object(id).callMethod('net.connman.Service', 'Connect', const [],
              replySignature: DBusSignature(''), noAutoStart: true);
        } finally {
          agent.pending = null;
        }
      });

  @override
  Future<void> disconnect(String id) => _call(() =>
      _object(id).callMethod('net.connman.Service', 'Disconnect', const [], replySignature: DBusSignature('')));

  @override
  Future<void> forget(String id) => _call(() =>
      _object(id).callMethod('net.connman.Service', 'Remove', const [], replySignature: DBusSignature('')));

  Future<_ConnmanAgent> _ensureAgent() async {
    final existing = _agent;
    if (existing != null) return existing;
    final agent = _ConnmanAgent(DBusObjectPath('/io/vrx/connman/agent$pid'));
    await _bus.registerObject(agent);
    await _manager.callMethod(_mgr, 'RegisterAgent', [agent.path], replySignature: DBusSignature(''));
    return _agent = agent;
  }
}

/// connman's agent: answers RequestInput with the passphrase the applet
/// supplies for the join in progress; anything else is canceled.
class _ConnmanAgent extends DBusObject {
  _ConnmanAgent(super.path);

  Future<String?> Function(String network)? pending;

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    if (call.interface != 'net.connman.Agent') return DBusMethodErrorResponse.unknownInterface();
    switch (call.name) {
      case 'RequestInput':
        final ask = pending;
        final fields = call.values[1].asStringVariantDict();
        if (ask == null || !fields.containsKey('Passphrase')) {
          return DBusMethodErrorResponse('net.connman.Agent.Error.Canceled');
        }
        final service = call.values[0].asObjectPath().value;
        final answer = await ask(service);
        if (answer == null) return DBusMethodErrorResponse('net.connman.Agent.Error.Canceled');
        return DBusMethodSuccessResponse([
          DBusDict.stringVariant({'Passphrase': DBusString(answer)}),
        ]);
      case 'ReportError':
      case 'Cancel':
      case 'Release':
        return DBusMethodSuccessResponse();
      default:
        return DBusMethodErrorResponse.unknownMethod();
    }
  }
}

// ── the installed set ─────────────────────────────────────────────────

/// The system services an applet uses. On a device they are the D-Bus
/// implementations, created on first use; tests and desktop runs install
/// their own.
abstract final class VrxSystem {
  static DBusClient? _bus;
  static TimeService? _time;
  static DeviceService? _device;
  static PowerService? _power;
  static NetworkService? _network;

  static DBusClient get _system => _bus ??= DBusClient.system();

  static TimeService get time => _time ??= DBusTimeService(_system);
  static DeviceService get device => _device ??= DBusDeviceService(_system);
  static PowerService get power => _power ??= LinuxPowerService(_system);
  static NetworkService get network => _network ??= ConnmanNetworkService(_system);

  /// Replace any of the services (tests, a desktop `flutter run`).
  static void install({
    TimeService? time,
    DeviceService? device,
    PowerService? power,
    NetworkService? network,
  }) {
    _network = network ?? _network;
    _time = time ?? _time;
    _device = device ?? _device;
    _power = power ?? _power;
  }
}

// ── D-Bus implementations ─────────────────────────────────────────────

Future<T> _call<T>(Future<T> Function() body) async {
  try {
    return await body();
  } on DBusMethodResponseException catch (err) {
    throw SystemError(err.errorName, err.response.values.isEmpty ? '' : '${err.response.values.first.toNative()}');
  }
}

/// A service's properties as a stream of states: read now, again on
/// every PropertiesChanged, and again when the service comes back under
/// a new owner (bus-activated services exit when idle and restart).
Stream<T> _watch<T>(
  DBusRemoteObject object,
  String interface,
  T Function(Map<String, DBusValue> properties) parse,
) {
  late StreamController<T> out;
  final subscriptions = <StreamSubscription<Object?>>[];
  Future<void> read() async {
    try {
      out.add(parse(await object.getAllProperties(interface)));
    } on Object catch (err) {
      out.addError(err);
    }
  }

  out = StreamController<T>(
    onListen: () {
      subscriptions
        ..add(object.propertiesChanged
            .where((s) => s.propertiesInterface == interface)
            .listen((_) => unawaited(read())))
        ..add(object.client.nameOwnerChanged
            .where((e) => e.name == object.name && e.newOwner != null)
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

class DBusTimeService implements TimeService {
  DBusTimeService(DBusClient bus)
      : _object = DBusRemoteObject(bus,
            name: 'org.freedesktop.timedate1',
            path: DBusObjectPath('/org/freedesktop/timedate1'));

  static const _iface = 'org.freedesktop.timedate1';
  final DBusRemoteObject _object;

  @override
  Stream<TimeState> watch() => _watch(
        _object,
        _iface,
        (p) => TimeState(
          zone: p['Timezone']?.asString() ?? '',
          automatic: p['NTP']?.asBoolean() ?? false,
          synced: p['NTPSynchronized']?.asBoolean() ?? false,
        ),
      );

  @override
  Future<void> setZone(String zone) => _call(() => _object.callMethod(
      _iface, 'SetTimezone', [DBusString(zone), const DBusBoolean(false)],
      replySignature: DBusSignature('')));

  @override
  Future<void> setAutomatic(bool on) => _call(() => _object.callMethod(
      _iface, 'SetNTP', [DBusBoolean(on), const DBusBoolean(false)],
      replySignature: DBusSignature('')));

  @override
  Future<void> setTime(DateTime time) => _call(() => _object.callMethod(
      _iface,
      'SetTime',
      [DBusInt64(time.microsecondsSinceEpoch), const DBusBoolean(false), const DBusBoolean(false)],
      replySignature: DBusSignature('')));

  @override
  Future<List<String>> zones() => _call(() async {
        final reply = await _object.callMethod(_iface, 'ListTimezones', const [],
            replySignature: DBusSignature('as'));
        return reply.returnValues.first.asStringArray().toList();
      });
}

class DBusDeviceService implements DeviceService {
  DBusDeviceService(DBusClient bus)
      : _object = DBusRemoteObject(bus,
            name: 'org.freedesktop.hostname1',
            path: DBusObjectPath('/org/freedesktop/hostname1'));

  static const _iface = 'org.freedesktop.hostname1';
  final DBusRemoteObject _object;

  /// The facts that do not change while the device runs, read once.
  late final Future<({String version, String model, String serial, int memoryMb})> _facts = () async {
    Future<String> read(String path) async {
      try {
        // device-tree strings end in NUL
        return (await File(path).readAsString()).replaceAll('\u0000', '').trim();
      } on FileSystemException {
        return '';
      }
    }

    final release = await read('/etc/os-release');
    final version = RegExp(r'^VERSION="?([^"\n]*)"?', multiLine: true).firstMatch(release)?.group(1) ?? '';
    final meminfo = await read('/proc/meminfo');
    final kb = int.tryParse(RegExp(r'^MemTotal:\s+(\d+)', multiLine: true).firstMatch(meminfo)?.group(1) ?? '') ?? 0;
    return (
      version: version,
      model: await read('/proc/device-tree/model'),
      serial: await read('/proc/device-tree/serial-number'),
      memoryMb: kb ~/ 1024,
    );
  }();

  @override
  Stream<DeviceState> watch() => _watch(_object, _iface, (p) {
        final hostname = p['StaticHostname']?.asString() ?? p['Hostname']?.asString() ?? '';
        final pretty = p['PrettyHostname']?.asString() ?? '';
        return (hostname: hostname, name: pretty.isEmpty ? hostname : pretty);
      }).asyncMap((names) async {
        final f = await _facts;
        return DeviceState(
          name: names.name,
          hostname: names.hostname,
          version: f.version,
          model: f.model,
          serial: f.serial,
          memoryMb: f.memoryMb,
        );
      });

  @override
  Future<void> setName(String name) => _call(() async {
        await _object.callMethod(_iface, 'SetPrettyHostname', [DBusString(name), const DBusBoolean(false)],
            replySignature: DBusSignature(''));
        await _object.callMethod(
            _iface, 'SetStaticHostname', [DBusString(hostnameFor(name)), const DBusBoolean(false)],
            replySignature: DBusSignature(''));
      });
}

/// logind for power, the sysfs backlight for the light.
class LinuxPowerService implements PowerService {
  LinuxPowerService(DBusClient bus, {this.backlightRoot = '/sys/class/backlight', this.hwmonRoot = '/sys/class/hwmon'})
      : _login = DBusRemoteObject(bus,
            name: 'org.freedesktop.login1',
            path: DBusObjectPath('/org/freedesktop/login1'));

  static const _manager = 'org.freedesktop.login1.Manager';
  final DBusRemoteObject _login;
  final String backlightRoot;
  final String hwmonRoot;

  @override
  Stream<bool> watchSupplyLow() async* {
    // the Raspberry Pi firmware's under-voltage alarm (hwmon "rpi_volt",
    // in0_lcrit_alarm): set below about 4.63 V at the module
    File? alarm;
    final root = Directory(hwmonRoot);
    if (!await root.exists()) return;
    await for (final dir in root.list()) {
      final name = File('${dir.path}/name');
      if (await name.exists() && (await name.readAsString()).trim() == 'rpi_volt') {
        alarm = File('${dir.path}/in0_lcrit_alarm');
      }
    }
    final file = alarm;
    if (file == null || !await file.exists()) return;
    Future<bool> read() async => (await file.readAsString()).trim() == '1';
    var last = await read();
    yield last;
    // like the backlight, a sysfs attribute with no inotify: a small read
    // every 2 s (the firmware re-checks about that often)
    await for (final _ in Stream<void>.periodic(const Duration(seconds: 2))) {
      final now = await read();
      if (now != last) yield last = now;
    }
  }

  @override
  Future<bool> canPowerOff() => _call(() async {
        final reply = await _login.callMethod(_manager, 'CanPowerOff', const [],
            replySignature: DBusSignature('s'));
        return reply.returnValues.first.asString() == 'yes';
      });

  @override
  Future<void> powerOff() => _call(() => _login.callMethod(
      _manager, 'PowerOff', [const DBusBoolean(false)],
      replySignature: DBusSignature('')));

  @override
  Future<void> reboot() => _call(() => _login.callMethod(
      _manager, 'Reboot', [const DBusBoolean(false)],
      replySignature: DBusSignature('')));

  Future<Directory?> _backlight() async {
    final root = Directory(backlightRoot);
    if (!await root.exists()) return null;
    final entries = await root.list().toList();
    return entries.isEmpty ? null : Directory(entries.first.path);
  }

  @override
  Future<int> lightLevels() async {
    final dir = await _backlight();
    if (dir == null) return 0;
    final max = int.tryParse((await File('${dir.path}/max_brightness').readAsString()).trim()) ?? 0;
    return max + 1;
  }

  @override
  Stream<bool> watchLight() async* {
    final dir = await _backlight();
    if (dir == null) return;
    final file = File('${dir.path}/brightness');
    Future<bool> read() async => (int.tryParse((await file.readAsString()).trim()) ?? 0) > 0;
    var last = await read();
    yield last;
    // sysfs attributes raise no inotify events, and the backlight core's
    // change uevent needs a netlink socket Dart does not have; the light
    // is changed by this service and by the compositor's idle timer, so a
    // 1 Hz read (one small sysfs read) catches the timer's changes
    await for (final _ in Stream<void>.periodic(const Duration(seconds: 1))) {
      final now = await read();
      if (now != last) yield last = now;
    }
  }

  @override
  Future<void> setLight(bool on) async {
    final dir = await _backlight();
    if (dir == null) throw const SystemError('vrx.NoBacklight', 'this device has no backlight');
    final max = (await File('${dir.path}/max_brightness').readAsString()).trim();
    try {
      await File('${dir.path}/brightness').writeAsString(on ? max : '0');
    } on FileSystemException catch (err) {
      throw SystemError('vrx.AccessDenied', 'the light needs the display grant: ${err.message}');
    }
  }
}
