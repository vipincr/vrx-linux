/// Shared state files: vrx's state IPC shape, from the applet side. A
/// value that stays true until it changes, readable and watchable by
/// anyone — /data/settings/* and friends, watched via inotify.
///
/// Direct file I/O from an applet is gated by the manifest's
/// permissions; this class is the sanctioned reader/watcher, and its
/// [VrxFile.writeAtomic] the one way a file is written whole (plan 0011
/// D4).
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// A watchable shared-state file.
abstract interface class VrxFile {
  /// The watched path.
  String get path;

  /// The current value (text), or null if the file does not exist.
  String? get value;

  /// Every value as it changes (and the current one on listen).
  Stream<String> get changes;

  /// Write [text] to [path] whole: a new file beside it, flushed, renamed
  /// over the old, so a power cut or a crash leaves one version or the
  /// other, never half of one. [mode] (octal, `0664`) is set before the
  /// rename for a file others read: an applet's unit has UMask=0077.
  static Future<void> writeAtomic(String path, String text, {String? mode}) async {
    final target = File(path);
    final tmp = File('${target.parent.path}/.${target.uri.pathSegments.last}.new');
    await target.parent.create(recursive: true);
    await tmp.writeAsString(text, flush: true);
    if (mode != null) {
      final chmod = await Process.run('chmod', [mode, tmp.path]);
      if (chmod.exitCode != 0) throw FileSystemException('chmod: ${chmod.stderr}'.trim(), tmp.path);
    }
    await tmp.rename(path);
  }

  /// Run [flush] before the applet stops (systemd's SIGTERM), so a write
  /// still waiting is not lost. Every flush gets two seconds together.
  static void flushOnStop(Future<void> Function() flush) {
    _flushers.add(flush);
    if (_watching || !Platform.isLinux) return;
    _watching = true;
    ProcessSignal.sigterm.watch().listen((_) async {
      try {
        await Future.wait([for (final f in _flushers) f()]).timeout(const Duration(seconds: 2));
      } on Object catch (err) {
        debugPrint('vrx: a write did not finish before stopping: $err');
      }
      exit(0);
    });
  }

  static final _flushers = <Future<void> Function()>[];
  static bool _watching = false;
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
