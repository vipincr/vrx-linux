/// Matter (plan 0015 D9): the kit's side of vrx-matter's `io.vrx.Matter`,
/// the one way an applet reaches the device's home-app pairing. The
/// `matter` grant (group vrx-matter) opens the socket; Settings holds it.
/// What a home app may see is the person's choice, kept in the system's
/// settings file (vrx.conf: `matter_screen`, `matter_expose`) and written
/// through [AppletSettings], the settings files' one writer.
library;

import 'dart:async';
import 'dart:io';

import 'host.dart';

/// The device on its fabrics, as vrx-matter says.
class MatterState {
  const MatterState({
    this.commissioned = false,
    this.fabrics = 0,
    this.window = false,
    this.windowUntil,
    this.ble = false,
    this.attestation = '',
  });

  factory MatterState.fromJson(Map<String, dynamic> j) => MatterState(
        commissioned: j['commissioned'] as bool? ?? false,
        fabrics: (j['fabrics'] as num?)?.toInt() ?? 0,
        window: j['window'] as bool? ?? false,
        windowUntil: switch ((j['window_until'] as num?)?.toInt()) {
          null || 0 => null,
          final s => DateTime.fromMillisecondsSinceEpoch(s * 1000),
        },
        ble: j['ble'] as bool? ?? false,
        attestation: j['attestation'] as String? ?? '',
      );

  /// On at least one home app's fabric.
  final bool commissioned;
  final int fabrics;

  /// The commissioning window is open: a home app may pair now.
  final bool window;
  final DateTime? windowUntil;
  final bool ble;

  /// `test` on a debug image: a home app warns the device is uncertified.
  final String attestation;

  @override
  bool operator ==(Object other) =>
      other is MatterState &&
      other.commissioned == commissioned &&
      other.fabrics == fabrics &&
      other.window == window &&
      other.windowUntil == windowUntil &&
      other.ble == ble &&
      other.attestation == attestation;

  @override
  int get hashCode => Object.hash(commissioned, fabrics, window, windowUntil, ble, attestation);
}

/// What a home app is shown while the window is open.
class MatterPayload {
  const MatterPayload({required this.qr, required this.manual});

  /// The QR code's text (`MT:...`).
  final String qr;

  /// The 11-digit manual pairing code.
  final String manual;

  /// The manual code as home apps print it: 1234-567-8901.
  String get pretty =>
      manual.length == 11 ? '${manual.substring(0, 4)}-${manual.substring(4, 7)}-${manual.substring(7)}' : manual;
}

/// An applet a home app may be shown: its manifest declares a Matter
/// block. Whether it is shown is the person's choice ([MatterExposure]).
class MatterApplet {
  const MatterApplet({required this.id, required this.name});

  final String id;
  final String name;
}

/// The person's choice, as vrx.conf keeps it (vrx_protocol::matter reads
/// it): the screen is shown unless switched off; applets only once named.
class MatterExposure {
  const MatterExposure({this.screen = true, this.applets = const []});

  factory MatterExposure.of(Map<String, String> vrxConf) => MatterExposure(
        screen: vrxConf['matter_screen'] != 'false',
        applets: [
          for (final id in (vrxConf['matter_expose'] ?? '').split(','))
            if (id.trim().isNotEmpty) id.trim(),
        ],
      );

  final bool screen;
  final List<String> applets;

  /// The `matter_expose` value with [id] switched [on] or off.
  String exposing(String id, {required bool on}) =>
      [for (final a in applets) if (a != id) a, if (on) id].join(',');
}

/// The service.
abstract class MatterService {
  /// The state now, and again on every change.
  Stream<MatterState> watch();

  /// Open the commissioning window, at most 15 minutes.
  Future<void> openWindow({int minutes = 15});

  Future<void> closeWindow();

  /// The pairing payload; only while the window is open.
  Future<MatterPayload> payload();

  /// The applets a home app may be shown.
  Future<List<MatterApplet>> applets();

  /// Leave every home app's fabric.
  Future<void> forget();
}

/// [MatterService] over vrx-matter's socket.
class VarlinkMatterService implements MatterService {
  VarlinkMatterService({this.socketPath = defaultSocket}) : _client = VarlinkClient(socketPath);

  static const defaultSocket = '/run/vrx-matter/io.vrx.Matter';

  final String socketPath;
  final VarlinkClient _client;

  @override
  Stream<MatterState> watch() =>
      resubscribed(() => _client.stream('io.vrx.Matter.State').map(MatterState.fromJson)).distinct();

  @override
  Future<void> openWindow({int minutes = 15}) => _client.call('io.vrx.Matter.OpenWindow', {'minutes': minutes});

  @override
  Future<void> closeWindow() => _client.call('io.vrx.Matter.CloseWindow');

  @override
  Future<MatterPayload> payload() async {
    final p = await _client.call('io.vrx.Matter.Payload');
    return MatterPayload(qr: p['qr'] as String? ?? '', manual: p['manual'] as String? ?? '');
  }

  @override
  Future<List<MatterApplet>> applets() async {
    final p = await _client.call('io.vrx.Matter.Endpoints');
    return [
      for (final a in (p['exposable'] as List? ?? const []))
        MatterApplet(id: (a as Map)['applet'] as String? ?? '', name: a['name'] as String? ?? ''),
    ];
  }

  @override
  Future<void> forget() => _client.call('io.vrx.Matter.Forget');
}

/// The installed Matter service: none where the image has no vrx-matter
/// (VRX_MATTER is off).
abstract final class VrxMatter {
  static MatterService? _service;
  static Future<MatterService?>? _found;

  /// The service once [find] has looked; null before, or where there is
  /// none.
  static MatterService? get service => _service;

  /// Look for vrx-matter's runtime directory, once.
  static Future<MatterService?> find() => _found ??= () async {
        const socket = VarlinkMatterService.defaultSocket;
        if (await Directory(socket.substring(0, socket.lastIndexOf('/'))).exists()) {
          _service ??= VarlinkMatterService();
        }
        return _service;
      }();

  /// Replace it (tests, a desktop `flutter run`).
  static void install(MatterService? service) {
    _service = service;
    _found = Future.value(service);
  }
}
