/// vrxhost from the applet side: [AppletsService], the domain API for the
/// back trail, the registry and intents (plan 0008 D3). Applets code
/// against the service, never against its transport; today it is
/// vrxhost's Varlink interface `io.vrx.Host` on `/run/vrx/io.vrx.Host`
/// ([VarlinkAppletsService]).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'intent.dart';
import 'nav.dart';

/// One tile's worth of registry: an applet the launcher shows.
class RegistryApplet {
  const RegistryApplet({
    required this.id,
    required this.name,
    required this.position,
    this.icon,
  });

  final String id;
  final String name;
  final int position;

  /// The manifest's display.icon: a VrxSymbols name.
  final String? icon;
}

/// What is on screen: the front applet and the trail depth.
class FrontApplet {
  const FrontApplet({required this.front, required this.depth});

  final String front;
  final int depth;
}

/// The applet OS's own service: navigation, the registry, intents.
abstract class AppletsService implements IntentTransport, NavDelegate {
  static AppletsService? _installed;

  /// The installed service, or null off-device (a desktop `flutter run`).
  static AppletsService? get installed => _installed;

  /// Install [service] (or the device's, when vrxhost's socket exists)
  /// as the [Intent] transport and the [Nav] delegate. Off-device nothing
  /// is installed, and Intent/Nav keep refusing loudly.
  static AppletsService? install([AppletsService? service]) {
    final chosen = service ?? VarlinkAppletsService.ifPresent();
    if (chosen == null) return null;
    Intent.install(chosen);
    Nav.install(chosen);
    return _installed = chosen;
  }

  /// The applets the launcher shows, in position order.
  Future<List<RegistryApplet>> applets();

  /// The front applet now, and again on every change.
  Stream<FrontApplet> watch();
}

/// A Varlink call failed: the error name and its parameters, as vrxhost
/// sent them (`io.vrx.Host.NoSuchApplet`, ...).
class VarlinkError implements Exception {
  const VarlinkError(this.name, this.parameters);

  final String name;
  final Map<String, dynamic> parameters;

  @override
  String toString() => 'VarlinkError($name, $parameters)';
}

/// A minimal Varlink client: JSON objects, NUL-terminated, on a unix
/// socket (varlink.org). One connection per call; `more` calls keep
/// theirs open and stream replies until the peer stops continuing.
class VarlinkClient {
  const VarlinkClient(this.socketPath);

  final String socketPath;

  /// Call [method] and return its reply parameters.
  Future<Map<String, dynamic>> call(String method,
      [Map<String, dynamic>? parameters]) async {
    return stream(method, parameters: parameters, more: false).first;
  }

  /// Call [method] and stream every reply's parameters.
  Stream<Map<String, dynamic>> stream(String method,
      {Map<String, dynamic>? parameters, bool more = true}) async* {
    final socket = await Socket.connect(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
    );
    try {
      final call = <String, dynamic>{
        'method': method,
        if (parameters != null) 'parameters': parameters,
        if (more) 'more': true,
      };
      socket.add([...utf8.encode(jsonEncode(call)), 0]);
      await socket.flush();
      final pending = <int>[];
      await for (final chunk in socket) {
        for (final byte in chunk) {
          if (byte != 0) {
            pending.add(byte);
            continue;
          }
          final reply = jsonDecode(utf8.decode(pending));
          pending.clear();
          if (reply is! Map<String, dynamic>) {
            throw FormatException('varlink reply is not an object', reply);
          }
          final params =
              (reply['parameters'] as Map<String, dynamic>?) ?? const {};
          final error = reply['error'];
          if (error is String) throw VarlinkError(error, params);
          yield params;
          if (reply['continues'] != true) return;
        }
      }
    } finally {
      socket.destroy();
    }
  }
}

/// [AppletsService] over vrxhost's `io.vrx.Host`.
class VarlinkAppletsService extends AppletsService {
  VarlinkAppletsService({String socketPath = defaultSocket})
      : _client = VarlinkClient(socketPath);

  /// vrxhost's socket.
  static const defaultSocket = '/run/vrx/io.vrx.Host';

  final VarlinkClient _client;

  /// The service when vrxhost's socket exists, else null.
  static VarlinkAppletsService? ifPresent({String socketPath = defaultSocket}) {
    // vrx-allow: once, at startup, before runApp and the first frame
    final type = FileSystemEntity.typeSync(socketPath);
    if (type != FileSystemEntityType.unixDomainSock) return null;
    return VarlinkAppletsService(socketPath: socketPath);
  }

  @override
  Future<List<RegistryApplet>> applets() async {
    final reply = await _client.call('io.vrx.Host.Applets');
    final list = reply['applets'];
    if (list is! List) return const [];
    return [
      for (final a in list.whereType<Map<String, dynamic>>())
        RegistryApplet(
          id: '${a['id']}',
          name: '${a['name']}',
          position: (a['position'] as num?)?.toInt() ?? 0,
          icon: a['icon'] as String?,
        ),
    ];
  }

  @override
  Stream<FrontApplet> watch() => _client.stream('io.vrx.Host.Watch').map(
        (p) => FrontApplet(
          front: '${p['front'] ?? ''}',
          depth: (p['depth'] as num?)?.toInt() ?? 0,
        ),
      );

  @override
  Future<IntentResult> send(String name, Object? payload) async {
    try {
      final reply = await _client.call('io.vrx.Host.Intent', {
        'name': name,
        if (payload != null) 'payload': payload,
      });
      return IntentResult(
        verdict: reply['verdict'] == 'pass' ? Verdict.pass : Verdict.handled,
        handledBy: reply['handled_by'] as String?,
        route: (reply['route'] as num?)?.toInt(),
      );
    } on VarlinkError catch (err) {
      return IntentResult(verdict: Verdict.error, error: err.name);
    } catch (err) {
      return IntentResult(verdict: Verdict.error, error: '$err');
    }
  }

  @override
  void push(String applet, {String route = ''}) => _nav('io.vrx.Host.Push',
      {'applet': applet, if (route.isNotEmpty) 'route': route});

  @override
  void pop() => _nav('io.vrx.Host.Pop');

  @override
  void home() => _nav('io.vrx.Host.Home');

  // Nav is fire-and-forget for the applet (the trail is vrxhost's); a
  // refusal is still said, never swallowed.
  void _nav(String method, [Map<String, dynamic>? parameters]) {
    unawaited(_client.call(method, parameters).then<void>((_) {}, onError: (Object err) {
      debugPrint('vrx: $method refused: $err');
    }));
  }
}
