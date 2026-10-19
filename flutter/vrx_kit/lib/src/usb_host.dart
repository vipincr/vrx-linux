/// The board's USB host ports (plan 0019): what is plugged in, the
/// policy that decides what may work, and what the image declared about
/// the ports' power. Linux enumerates and authorises; vrxhost hears the
/// kernel and publishes it in `io.vrx.Host.Facts`, so this is a view of
/// that stream plus two actions (eject a drive, "Allow new USB devices")
/// for a built-in holding the `usb` grant.
///
/// The device side (a computer enumerating the board's gadget) is
/// [UsbService] in system.dart; the two are named apart on purpose.
library;

import 'host.dart';

/// What a device is, in the closed set vrxhost and camerad share.
enum UsbClass {
  hid,
  storage,
  audio,
  video,
  serial,
  hub,
  other;

  static UsbClass parse(Object? s) => switch (s) {
        'hid' => hid,
        'storage' => storage,
        'audio' => audio,
        'video' => video,
        'serial' => serial,
        'hub' => hub,
        _ => other,
      };
}

/// One device plugged into the board.
class UsbDevice {
  const UsbDevice({
    required this.port,
    this.name = '',
    this.cls = UsbClass.other,
    this.id = '',
    this.speed = '',
    this.authorized = true,
    this.blocked = false,
    this.mounts = const [],
  });

  factory UsbDevice.fromJson(Map<String, dynamic> j) => UsbDevice(
        port: '${j['port'] ?? ''}',
        name: '${j['name'] ?? ''}',
        cls: UsbClass.parse(j['class']),
        id: '${j['id'] ?? ''}',
        speed: '${j['speed'] ?? ''}',
        authorized: j['authorized'] != false,
        blocked: j['blocked'] == true,
        mounts: [for (final m in (j['mounts'] as List? ?? const [])) '$m'],
      );

  /// Its place on the bus (`1-1.2`), stable while it stays in that port.
  final String port;

  /// What it calls itself ('' when it says nothing).
  final String name;
  final UsbClass cls;

  /// vendor:product.
  final String id;

  /// Mb/s as the kernel says it.
  final String speed;
  final bool authorized;

  /// The policy kept it from working.
  final bool blocked;

  /// A drive's partitions, mounted read-only under /run/vrx/usb.
  final List<String> mounts;

  @override
  bool operator ==(Object other) =>
      other is UsbDevice &&
      other.port == port &&
      other.name == name &&
      other.cls == cls &&
      other.id == id &&
      other.speed == speed &&
      other.authorized == authorized &&
      other.blocked == blocked &&
      _same(other.mounts, mounts);

  @override
  int get hashCode => Object.hash(port, name, cls, id, speed, authorized, blocked, Object.hashAll(mounts));
}

bool _same(List<Object?> a, List<Object?> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The policy as vrxhost reports it.
enum UsbPolicy {
  /// The board has no host ports.
  none,

  /// A debug image: everything works.
  open,

  /// The image's allow-list decides.
  allowlist,

  /// The allow-list's daemon is not running: nothing newly plugged in
  /// works.
  failed;

  /// A word the policy never spells is an error, not `none`: an unknown
  /// word reading as none made Settings claim USB was open when it was
  /// not (INT-10, review 2026-10-17).
  static UsbPolicy parse(Object? s) => switch (s) {
        'open' => open,
        'allowlist' => allowlist,
        'failed' => failed,
        'none' => none,
        _ => throw FormatException(
            'io.vrx.Host.Facts: unknown usb_policy "$s"; the wire changed '
            'under this build (rebuild the applet against vrxhost)'),
      };
}

/// The host side now.
class UsbHostState {
  const UsbHostState({
    this.ports = const [],
    this.vbus = '',
    this.overcurrent = '',
    this.policy = UsbPolicy.none,
    this.allowNew = true,
    this.devices = const [],
  });

  /// Strict like SystemFacts: a missing key or an unknown policy word is
  /// an error naming it, never a default (INT-10; an unknown policy word
  /// once read as `none` and Settings said USB was open when it was not).
  factory UsbHostState.fromJson(Map<String, dynamic> j) {
    if (!j.containsKey('usb_ports') ||
        !j.containsKey('usb_vbus') ||
        !j.containsKey('usb_overcurrent') ||
        !j.containsKey('usb_policy') ||
        !j.containsKey('usb_allow_new') ||
        !j.containsKey('usb_devices')) {
      throw FormatException(
          'io.vrx.Host.Facts: the USB reply is missing a key the kit reads '
          '(usb_ports, usb_vbus, usb_overcurrent, usb_policy, usb_allow_new, '
          'usb_devices); the wire changed under this build');
    }
    return UsbHostState(
      ports: [for (final p in (j['usb_ports'] as List? ?? const [])) '$p'],
      vbus: '${j['usb_vbus']}',
      overcurrent: '${j['usb_overcurrent']}',
      policy: UsbPolicy.parse(j['usb_policy']),
      allowNew: j['usb_allow_new'] != false,
      devices: [
        for (final d in (j['usb_devices'] as List? ?? const []).whereType<Map<String, dynamic>>()) UsbDevice.fromJson(d),
      ],
    );
  }

  /// The host ports' labels, as the image declared them; empty: none.
  final List<String> ports;

  /// unswitched, switched or unknown.
  final String vbus;

  /// none, reported or unknown.
  final String overcurrent;
  final UsbPolicy policy;

  /// "Allow new USB devices", as vrxhost last set it.
  final bool allowNew;
  final List<UsbDevice> devices;

  /// The board has a host port.
  bool get present => ports.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is UsbHostState &&
      _same(other.ports, ports) &&
      other.vbus == vbus &&
      other.overcurrent == overcurrent &&
      other.policy == policy &&
      other.allowNew == allowNew &&
      _same(other.devices, devices);

  @override
  int get hashCode => Object.hash(Object.hashAll(ports), vbus, overcurrent, policy, allowNew, Object.hashAll(devices));
}

/// The service.
abstract class UsbHostService {
  /// The host side now, and again on every change.
  Stream<UsbHostState> watch();

  /// Eject a drive: each of its mounts stops (the usb grant).
  Future<void> eject(UsbDevice device);

  /// "Allow new USB devices" (the usb grant; only under the allow-list).
  Future<void> allowNew(bool on);
}

/// [UsbHostService] over vrxhost's `io.vrx.Host`.
class VarlinkUsbHostService implements UsbHostService {
  VarlinkUsbHostService({String socketPath = VarlinkAppletsService.defaultSocket}) : _client = VarlinkClient(socketPath);

  final VarlinkClient _client;

  @override
  Stream<UsbHostState> watch() =>
      AppletsService.installed?.facts().map((f) => f.usbHost).distinct() ?? Stream.value(const UsbHostState());

  @override
  Future<void> eject(UsbDevice device) async {
    for (final mount in device.mounts) {
      await _client.call('io.vrx.Host.UsbEject', {'mount': mount});
    }
  }

  @override
  Future<void> allowNew(bool on) => _client.call('io.vrx.Host.UsbPolicy', {'allow_new': on});
}

/// The installed service (vrxhost's; replaced in tests).
abstract final class VrxUsbHost {
  static UsbHostService? _service;

  static UsbHostService get service => _service ??= VarlinkUsbHostService();

  /// Replace it (tests, a desktop `flutter run`).
  static void install(UsbHostService service) => _service = service;
}
