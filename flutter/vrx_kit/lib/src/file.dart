/// Shared state files: vrx's state IPC shape, from the applet side. A
/// value that stays true until it changes, readable and watchable by
/// anyone — /data/settings/* and friends, watched via inotify.
///
/// Direct file I/O from an applet is gated by the manifest's
/// permissions (checked at build time by vrx_lints); this class is
/// the sanctioned reader/watcher.
library;

/// A watchable shared-state file.
abstract interface class VrxFile {
  /// The watched path.
  String get path;

  /// The current value (text), or null if the file does not exist.
  String? get value;

  /// Every value as it changes (and the current one on listen).
  Stream<String> get changes;
}

/// VrxFile's connection to the filesystem, via the runtime.
abstract interface class FileTransport {
  /// Watch a path.
  VrxFile watch(String path);
}

/// Watch shared state files.
abstract final class VrxFiles {
  static FileTransport? _transport;

  /// Install the transport (the runtime, once, at startup).
  static void install(FileTransport transport) => _transport = transport;

  /// Watch a shared-state file by path.
  static VrxFile watch(String path) {
    final transport = _transport;
    if (transport == null) {
      throw StateError(
        'VrxFiles: no transport installed — vrxhost is not running. '
        'The flutter-vrx runtime installs one at startup; tests install '
        'a recording fake.',
      );
    }
    return transport.watch(path);
  }
}
