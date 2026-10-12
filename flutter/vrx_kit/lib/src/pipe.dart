/// Pipes: vrx's stream IPC shape, from the applet side. Ordered
/// records, one writer to one reader, with backpressure. A Unix
/// socket in /tmp/vrx/pipes/, surfaced through the runtime-installed
/// transport (same rule as Intent: no transport, clear error).
library;

/// A handle on one pipe.
abstract interface class Pipe {
  /// The pipe's dotted name (`audio.samples`).
  String get name;

  /// Write one JSON-encodable record.
  Future<void> write(Object? record);

  /// The records arriving on this pipe.
  Stream<Object?> get records;
}

/// Pipe's connection to vrxhost.
abstract interface class PipeTransport {
  /// Open a pipe by name for reading, writing, or both.
  Future<Pipe> open(String name);
}

/// Open pipes.
abstract final class Pipes {
  static PipeTransport? _transport;

  /// Install the transport (the runtime, once, at startup).
  static void install(PipeTransport transport) => _transport = transport;

  /// Open a pipe by name.
  static Future<Pipe> open(String name) {
    final transport = _transport;
    if (transport == null) {
      throw StateError(
        'Pipes: no transport installed — vrxhost is not running. '
        'The flutter-vrx runtime installs one at startup; tests install '
        'a recording fake.',
      );
    }
    return transport.open(name);
  }
}
