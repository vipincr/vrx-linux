/// vrxhost from the applet side: the intent socket client that backs
/// [Intent] and [Nav] on a device. One request per connection,
/// newline-delimited JSON (`{"name": ..., "payload": ...}` out, one
/// JSON object back), the wire vrxhost's intent router serves.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'intent.dart';
import 'nav.dart';

/// One tile's worth of registry: what `vrx.registry.list` returns per
/// applet (display.tile applets, in position order).
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

  /// The manifest's display.icon: a file name or a glyph.
  final String? icon;
}

/// The vrxhost client. Installed by [VrxHost.installIfPresent] (which
/// `runApplet` calls), so applets never construct it themselves.
class VrxHost implements IntentTransport, NavDelegate {
  VrxHost({this.socketPath = defaultSocket});

  /// vrxhost's intent socket.
  static const defaultSocket = '/tmp/vrx/vrx.sock';

  final String socketPath;

  static VrxHost? _installed;

  /// The installed client, or null off-device.
  static VrxHost? get installed => _installed;

  /// Install as the [Intent] transport and the [Nav] delegate when the
  /// socket exists. Off-device (a desktop `flutter run`) nothing is
  /// installed, and Intent/Nav keep refusing loudly.
  static VrxHost? installIfPresent({String socketPath = defaultSocket}) {
    if (FileSystemEntity.typeSync(socketPath) != FileSystemEntityType.unixDomainSock) {
      return null;
    }
    final host = VrxHost(socketPath: socketPath);
    Intent.install(host);
    Nav.install(host);
    return _installed = host;
  }

  /// One request, one answer.
  Future<Map<String, dynamic>> request(String name, [Object? payload]) async {
    final socket = await Socket.connect(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
    );
    try {
      socket.write('${jsonEncode({'name': name, 'payload': payload})}\n');
      await socket.flush();
      final line = await utf8.decoder
          .bind(socket)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 5));
      final answer = jsonDecode(line);
      if (answer is! Map<String, dynamic>) {
        throw FormatException('vrxhost answered a non-object', line);
      }
      return answer;
    } finally {
      socket.destroy();
    }
  }

  @override
  Future<IntentResult> send(String name, Object? payload) async {
    try {
      return resultOf(await request(name, payload));
    } catch (err) {
      return IntentResult(verdict: Verdict.error, error: '$err');
    }
  }

  /// The applets the launcher shows.
  Future<List<RegistryApplet>> applets() async {
    final answer = await request('vrx.registry.list');
    final list = answer['applets'];
    if (answer['ok'] != true || list is! List) {
      throw StateError('vrx.registry.list: ${answer['error'] ?? answer}');
    }
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
  void push(String applet, {String route = ''}) =>
      _nav('vrx.nav.push', {'applet': applet, if (route.isNotEmpty) 'route': route});

  @override
  void pop() => _nav('vrx.nav.pop');

  @override
  void home() => _nav('vrx.nav.home');

  // Nav is fire-and-forget for the applet (the trail is vrxhost's); a
  // refusal is still said, never swallowed.
  void _nav(String name, [Object? payload]) {
    unawaited(send(name, payload).then((result) {
      if (result.verdict == Verdict.error) {
        debugPrint('vrx: $name refused: ${result.error ?? result}');
      }
    }));
  }

  /// Map a vrxhost answer onto an [IntentResult].
  @visibleForTesting
  static IntentResult resultOf(Map<String, dynamic> answer) {
    if (answer['ok'] != true) {
      return IntentResult(
        verdict: Verdict.error,
        errno: (answer['errno'] as num?)?.toInt(),
        error: answer['error'] as String?,
      );
    }
    return IntentResult(
      verdict: answer['verdict'] == 'pass' ? Verdict.pass : Verdict.handled,
      handledBy: answer['handled_by'] as String?,
      route: (answer['route'] as num?)?.toInt(),
    );
  }
}
