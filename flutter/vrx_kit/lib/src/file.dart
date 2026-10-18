/// Whole-file writes and stop-time flushes: the applet side of shared
/// state files. Watching is the host's (the Facts and settings IPC), and
/// direct file I/O from an applet is gated by the manifest's permissions;
/// [VrxFile.writeAtomic] is the one way a file is written whole (plan
/// 0011 D4).
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

/// Whole-file writes and stop-time flushes.
final class VrxFile {
  VrxFile._();

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
  /// still waiting is not lost, and before the system sleeps (the
  /// compositor relays logind's PrepareForSleep as
  /// AppLifecycleState.paused and holds the sleep for a second, plan 0012
  /// D14). Every flush gets two seconds together.
  static void flushOnStop(Future<void> Function() flush) {
    _flushers.add(flush);
    if (_watching || !Platform.isLinux) return;
    _watching = true;
    // the binding keeps the listener for the applet's life
    AppLifecycleListener(
      binding: WidgetsFlutterBinding.ensureInitialized(),
      onPause: () => unawaited(_flushAll()),
    );
    ProcessSignal.sigterm.watch().listen((_) async {
      try {
        await Future.wait([for (final f in _flushers) f()]).timeout(const Duration(seconds: 2));
      } on Object catch (err) {
        debugPrint('vrx: a write did not finish before stopping: $err');
      }
      exit(0);
    });
  }

  static Future<void> _flushAll() async {
    try {
      await Future.wait([for (final f in _flushers) f()]).timeout(const Duration(seconds: 2));
    } on Object catch (err) {
      debugPrint('vrx: a write did not finish before the system slept: $err');
    }
  }

  static final _flushers = <Future<void> Function()>[];
  static bool _watching = false;
}
