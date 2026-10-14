/// vrxhost from the applet side: [AppletsService], the domain API for the
/// back trail, the registry and intents (plan 0008 D3). Applets code
/// against the service, never against its transport; today it is
/// vrxhost's Varlink interface `io.vrx.Host` on `/run/vrx/io.vrx.Host`
/// ([VarlinkAppletsService]).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'intent.dart';
import 'nav.dart';
import 'settings.dart';
import 'words.dart';

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

/// An applet offered for installing (plan 0011 D16): an extension image
/// in /var/lib/vrx/offers, read and checked by vrxhost without merging it.
class AppOffer {
  const AppOffer({
    required this.file,
    required this.id,
    required this.name,
    required this.version,
    required this.build,
    required this.kind,
    this.installed,
    this.problem,
  });

  factory AppOffer.fromJson(Map<String, dynamic> j) => AppOffer(
        file: '${j['file'] ?? ''}',
        id: '${j['id'] ?? ''}',
        name: '${j['name'] ?? ''}',
        version: '${j['version'] ?? ''}',
        build: '${j['build'] ?? ''}',
        kind: '${j['kind'] ?? ''}',
        installed: j['installed'] as String?,
        problem: j['problem'] as String?,
      );

  final String file, id, name, version;

  /// The image's SHA-256: what the person agrees to.
  final String build;

  /// install, update, replace, older or same.
  final String kind;

  /// The installed version, when one is.
  final String? installed;

  /// Why it cannot be installed (vrxhost's key), when it cannot.
  final String? problem;

  /// It can be installed now, and doing so changes something.
  bool get installable => problem == null && (kind == 'install' || kind == 'update' || kind == 'replace');
}

/// What is on screen: the front applet and the trail depth.
class FrontApplet {
  const FrontApplet({required this.front, required this.depth, this.stopped});

  final String front;

  /// The trail's entries, Home included: 1 at Home.
  final int depth;

  /// An applet whose unit just failed or restarted after a crash (its
  /// id), for the shell to say once (plan 0011 D2); null otherwise.
  final String? stopped;
}

/// System facts that change, heard from vrxhost rather than polled (plan
/// 0012 D6): the USB device port's state, the supply alarm, and a count of
/// backlight changes (read the level again when it moves).
class SystemFacts {
  const SystemFacts({
    this.usb = '',
    this.supplyLow = false,
    this.backlight = 0,
    this.battery = -1,
    this.batteryZone = '',
    this.nextWake = 0,
  });

  factory SystemFacts.fromJson(Map<String, dynamic> j) => SystemFacts(
        usb: '${j['usb'] ?? ''}',
        supplyLow: j['supply_low'] == true,
        backlight: (j['backlight'] as num?)?.toInt() ?? 0,
        battery: (j['battery'] as num?)?.toInt() ?? -1,
        batteryZone: '${j['battery_zone'] ?? ''}',
        nextWake: (j['next_wake'] as num?)?.toInt() ?? 0,
      );

  /// The UDC's state ("configured" with a computer on the cable); '' on a
  /// board with no USB device port.
  final String usb;

  /// The supply is below the board's alarm.
  final bool supplyLow;

  /// Changes to the backlight's level so far.
  final int backlight;

  /// The battery's charge in percent, as vrxhost shows it (plan 0012
  /// D10); -1 where there is no battery.
  final int battery;

  /// '', 'warn' or 'critical' while discharging: at 'critical' the device
  /// powers off in 30 seconds unless it goes on a charger.
  final String batteryZone;

  /// The earliest time (unix seconds) an applet asked the system to wake
  /// for, Clock's next alarm; 0 = none.
  final int nextWake;
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

  /// The system's changing facts now, and again on every change.
  Stream<SystemFacts> facts();

  /// Every applet's declared settings (plan 0008 D5).
  Future<List<AppletSettingsDecl>> settings();

  /// The applets offered for installing (plan 0011 D16; the apps grant).
  Future<List<AppOffer>> offers();

  /// Install [offer], refused if its build is no longer the one agreed
  /// to. Answers the installed applet's id.
  Future<String> installOffer(AppOffer offer);

  /// Uninstall an installed applet: its image, unit drop-in, saved state,
  /// cache and settings go.
  Future<void> uninstall(String applet);

  /// Wake the system at [at] for this applet's next alarm or timer (plan
  /// 0012 D15), replacing what it asked before; null cancels. For applets
  /// holding the time grant; a board with no RTC keeps the request and
  /// cannot wake for it.
  Future<void> wakeAt(DateTime? at);

  /// Where this applet was last opened (plan 0011 D5): the route ('' is
  /// the root; one it does not declare arrives as ''), and the payload of
  /// the intent that opened it there.
  Future<({String route, Object? payload})> route();
}

/// A `more` call that outlives vrxhost: when its connection ends (vrxhost
/// restarted, or is not up yet) it is made again after [retry]. Without
/// it the shell kept the trail depth of a vrxhost that had gone, and
/// offered no Back in an applet (bench 2026-10-13).
Stream<T> resubscribed<T>(Stream<T> Function() open, {Duration retry = const Duration(milliseconds: 500)}) async* {
  while (true) {
    try {
      // await for, not yield*: an error must end this attempt here, not
      // reach the listener
      await for (final value in open()) {
        yield value;
      }
    } on Object {
      // gone or refused: the next attempt says whether it is back
    }
    await Future<void>.delayed(retry); // poll-ok: only while vrxhost is down or restarting, to reconnect
  }
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
  Future<List<AppletSettingsDecl>> settings() async {
    final reply = await _client.call('io.vrx.Host.Settings');
    final list = reply['applets'];
    if (list is! List) return const [];
    return [
      for (final a in list.whereType<Map<String, dynamic>>())
        AppletSettingsDecl(
          id: '${a['id']}',
          name: '${a['name']}',
          settings: [
            for (final s in (a['settings'] as List? ?? const []).whereType<Map<String, dynamic>>()) SettingDecl.fromJson(s),
          ],
        ),
    ];
  }

  @override
  Future<List<AppOffer>> offers() async {
    final reply = await _client.call('io.vrx.Host.Offers');
    final list = reply['offers'];
    if (list is! List) return const [];
    return [for (final o in list.whereType<Map<String, dynamic>>()) AppOffer.fromJson(o)];
  }

  @override
  Future<String> installOffer(AppOffer offer) async {
    final reply = await _client.call('io.vrx.Host.Install', {'file': offer.file, 'build': offer.build});
    return '${reply['id'] ?? offer.id}';
  }

  @override
  Future<void> uninstall(String applet) => _client.call('io.vrx.Host.Uninstall', {'applet': applet});

  @override
  Future<void> wakeAt(DateTime? at) =>
      _client.call('io.vrx.Host.WakeAt', {'at': at == null ? null : at.millisecondsSinceEpoch ~/ 1000});

  @override
  Future<({String route, Object? payload})> route() async {
    final reply = await _client.call('io.vrx.Host.Route');
    return (route: reply['route'] as String? ?? '', payload: reply['payload']);
  }

  @override
  Stream<FrontApplet> watch() => resubscribed(
      () => _client.stream('io.vrx.Host.Watch').map(
            (p) => FrontApplet(
              front: '${p['front'] ?? ''}',
              depth: (p['depth'] as num?)?.toInt() ?? 0,
              stopped: p['stopped'] as String?,
            ),
          ));

  @override
  Stream<SystemFacts> facts() => resubscribed(() => _client.stream('io.vrx.Host.Facts').map(SystemFacts.fromJson));

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
  Future<NavOutcome> push(String applet, {String route = ''}) => _nav('io.vrx.Host.Push',
      {'applet': applet, if (route.isNotEmpty) 'route': route});

  @override
  Future<NavOutcome> pop() => _nav('io.vrx.Host.Pop');

  @override
  Future<NavOutcome> home() => _nav('io.vrx.Host.Home');

  // The trail is vrxhost's; its answer is the outcome, and a refusal is
  // said in a sentence (plan 0011 D2), never swallowed.
  Future<NavOutcome> _nav(String method, [Map<String, dynamic>? parameters]) async {
    try {
      await _client.call(method, parameters);
      return const NavOutcome.done();
    } on Object catch (err) {
      return NavOutcome.refused(VrxWords.of(err, context: '$method refused'));
    }
  }
}
