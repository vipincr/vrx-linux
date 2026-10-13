/// What a person reads when something they asked for did not happen
/// (plan 0011 D2): one sentence, in their words, from one table. Nothing
/// in Linux or Flutter phrases a refusal for a person, so vrx does it
/// here, once.
///
/// The rules (evrx-rt docs/13 §Words, AGENTS.md 3.1): a full sentence;
/// say what happened and, when there is one, what to do; never a raw
/// exception, an error name or a stack trace. The details go to the log
/// ([VrxWords.of] logs them), never to the screen.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';

import 'host.dart';
import 'system.dart';

abstract final class VrxWords {
  /// When nothing better is known.
  static const failed = 'That did not work. The details are in the log.';

  /// The service refused for lack of a grant.
  static const notAllowed = 'This applet is not allowed to do that.';

  /// vrxhost is not answering.
  static const noHost = 'The system is not answering. Try again in a moment.';

  /// A Varlink error from vrxhost (navigation, intents, the bridge).
  static String host(VarlinkError err) {
    final name = err.name.split('.').last;
    switch (name) {
      case 'NoSuchApplet':
        return 'That applet is not on this device.';
      case 'NotOpenable':
        return 'That applet has no screen to open.';
      case 'Disabled':
        return 'That applet stopped several times in a row, so it is turned off until the device restarts.';
      case 'Unavailable':
        return noHost;
      case 'NoHandler':
        return 'No applet on this device can do that.';
      case 'NotDeclared':
        return 'This applet did not declare that, so the system refused it.';
      case 'Reserved':
        return 'Only the system may send that.';
      case 'PayloadTooLarge':
        return 'That was too much to send at once.';
      case 'NotListening':
        return 'The other applet is not running.';
    }
    return failed;
  }

  /// An error from a system service (connman, timedated, hostnamed,
  /// logind, localed, BlueZ, systemd).
  static String system(SystemError err) {
    if (err.denied) return notAllowed;
    final name = err.name;
    // connman
    if (name.endsWith('InvalidKey') || err.message.contains('invalid-key')) {
      return 'The passphrase was not accepted. Check it and try again.';
    }
    if (name.endsWith('AlreadyConnected')) return 'The device is already on that network.';
    if (name.endsWith('NotConnected')) return 'The device is not on that network.';
    if (name.endsWith('InProgress')) return 'The device is already doing that. Wait a moment.';
    if (name.endsWith('NotSupported')) return 'This device cannot do that.';
    if (name.endsWith('NotFound') || name.endsWith('NoSuchService')) return 'That is no longer there.';
    if (name.endsWith('Timeout') || name.endsWith('NoReply')) return 'It took too long to answer. Try again.';
    // timedated: SetTime while network time is on
    if (name.endsWith('AutomaticTimeSyncEnabled')) {
      return 'Turn off network time first; the clock is set from the network.';
    }
    if (name.endsWith('ServiceUnknown') || name.endsWith('NameHasNoOwner')) return noHost;
    return failed;
  }

  /// A failed file write or read.
  static String file(FileSystemException err) {
    switch (err.osError?.errorCode) {
      case 28: // ENOSPC
        return 'There is no room left to save it.';
      case 30: // EROFS
      case 13: // EACCES
      case 1: // EPERM
        return 'This applet is not allowed to save there.';
      case 2: // ENOENT
        return 'That file is no longer there.';
      case 5: // EIO
        return 'The storage stopped answering. The file may be incomplete.';
    }
    return failed;
  }

  /// Any error, in one sentence; the details go to the log.
  static String of(Object err, {String? context}) {
    debugPrint('vrx: ${context == null ? '' : '$context: '}$err');
    return switch (err) {
      SystemError e => system(e),
      VarlinkError e => host(e),
      FileSystemException e => file(e),
      SocketException _ => 'The device could not reach it. Check the network.',
      _ => failed,
    };
  }
}
