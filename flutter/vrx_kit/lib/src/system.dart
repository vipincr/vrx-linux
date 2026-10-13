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

/// What the device is called and what it is.
class DeviceState {
  const DeviceState({
    required this.name,
    required this.hostname,
    required this.system,
    required this.model,
  });

  /// The name a person gave it (pretty hostname), or the hostname.
  final String name;

  /// The network name (static hostname).
  final String hostname;

  /// The OS (`vrx 0.1.0074 (cm4-bcm2711)`).
  final String system;

  /// The hardware, from the device tree when the firmware says.
  final String model;
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

  static DBusClient get _system => _bus ??= DBusClient.system();

  static TimeService get time => _time ??= DBusTimeService(_system);
  static DeviceService get device => _device ??= DBusDeviceService(_system);
  static PowerService get power => _power ??= LinuxPowerService(_system);

  /// Replace any of the services (tests, a desktop `flutter run`).
  static void install({TimeService? time, DeviceService? device, PowerService? power}) {
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

  @override
  Stream<DeviceState> watch() => _watch(_object, _iface, (p) {
        final hostname = p['StaticHostname']?.asString() ?? p['Hostname']?.asString() ?? '';
        final pretty = p['PrettyHostname']?.asString() ?? '';
        return DeviceState(
          name: pretty.isEmpty ? hostname : pretty,
          hostname: hostname,
          system: p['OperatingSystemPrettyName']?.asString() ?? '',
          model: p['HardwareModel']?.asString() ?? '',
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
  LinuxPowerService(DBusClient bus, {this.backlightRoot = '/sys/class/backlight'})
      : _login = DBusRemoteObject(bus,
            name: 'org.freedesktop.login1',
            path: DBusObjectPath('/org/freedesktop/login1'));

  static const _manager = 'org.freedesktop.login1.Manager';
  final DBusRemoteObject _login;
  final String backlightRoot;

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
