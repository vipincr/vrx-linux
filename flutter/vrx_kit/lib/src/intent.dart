/// Intents: vrx's signal IPC shape, from the applet side. Something
/// happened or is asked; small; has a verdict. Names are dotted
/// lower-case, two-plus segments, each starting with a letter
/// (`sys.alarm.ring`).
///
/// The runtime installs a transport that speaks the vrxhost wire
/// protocol (newline-delimited JSON on /tmp/vrx/vrx.sock); until one
/// is installed, sending refuses with a clear error — an applet
/// degraded standalone never silently drops an intent.
library;

/// The verdict a handler returned. The three wire words (opened, handled,
/// pass) are the IDL's; error is the kit's own (the call itself failed).
enum Verdict {
  /// A handler was pushed at its route (the caller is now on screen).
  opened,

  /// The handler took the intent.
  handled,

  /// Everyone passed; the intent was dropped.
  pass,

  /// The handler failed.
  error,
}

/// An intent's answer: what happened, who handled it, at which route
/// (for an opened handler).
class IntentResult {
  const IntentResult({
    required this.verdict,
    this.handledBy,
    this.route,
    this.errno,
    this.error,
  });

  final Verdict verdict;
  final String? handledBy;
  final int? route;
  final int? errno;
  final String? error;

  @override
  String toString() =>
      'IntentResult(${verdict.name}, handledBy: $handledBy, route: $route'
      '${errno == null ? '' : ', errno: $errno'})';
}

/// Intent's connection to vrxhost. The flutter-vrx runtime installs
/// this at startup; tests install a recording fake.
abstract interface class IntentTransport {
  /// Send one intent, settle with its result.
  Future<IntentResult> send(String name, Object? payload);
}

/// Send intents.
abstract final class Intent {
  static IntentTransport? _transport;

  /// Install the transport (the runtime, once, at startup).
  static void install(IntentTransport transport) => _transport = transport;

  /// Send an intent by name with a JSON-encodable payload.
  static Future<IntentResult> send(String name, [Object? payload]) {
    final transport = _transport;
    if (transport == null) {
      throw StateError(
        'Intent: no transport installed — vrxhost is not running. '
        'The flutter-vrx runtime installs one at startup; tests install '
        'a recording fake.',
      );
    }
    return transport.send(name, payload);
  }
}
