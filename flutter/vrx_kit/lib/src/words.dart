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
      case 'NotPermitted':
        return notAllowed;
      case 'Busy':
        return 'A home app is pairing over Bluetooth. Try again when it is done.';
      case 'OfferChanged':
        return 'That app changed after it was offered. Look at it again before installing it.';
      case 'OfferRefused':
        return offerProblem('${err.parameters['reason'] ?? ''}');
      case 'NotInstalled':
        return 'That applet is part of the system, so it cannot be uninstalled.';
      case 'InstallFailed':
        return 'The app did not install. The details are in the log.';
      case 'UpdateRefused':
        return updateProblem('${err.parameters['reason'] ?? ''}');
      case 'UpdateFailed':
        final reason = '${err.parameters['reason'] ?? ''}';
        return reason == 'space' || reason == 'unsigned' || reason == 'machine'
            ? updateProblem(reason)
            : 'The update did not install. The device is unchanged, and the details are in the log.';
    }
    return failed;
  }

  /// Why an offered app cannot be installed (vrxhost's reasons).
  static String offerProblem(String reason) => switch (reason) {
        'name' => 'That app is named like something else on this device.',
        'paths' => 'That app would change files outside its own folder, so it is refused.',
        'release' => 'That app was made for another version of this system.',
        'manifest' => 'That app asks for more than an installed app may have.',
        'builtin' => 'That app has the name of one of the system\'s own.',
        'flutter' => 'That app was built for another version of the system\'s Flutter.',
        'unreadable' => 'That file is not an app this device can read.',
        'unsigned' => 'That app is not signed, and this device installs only signed apps.',
        'untrusted' => 'That app is signed by someone this device does not trust.',
        'off' => 'This device does not install apps.',
        _ => 'That app cannot be installed on this device.',
      };

  /// Why an offered update cannot be installed (vrxhost's reasons, plan
  /// 0016 D7, D11).
  static String updateProblem(String reason) => switch (reason) {
        'unsigned' => 'That update is not signed by this device\'s maker, so it is refused.',
        'machine' => 'That update is for another kind of device.',
        'older' => 'That update is older than the software running now.',
        'same' => 'That is the version running now.',
        'space' => 'There is not enough room to install that update.',
        'gone' => 'That update is no longer there. Look again.',
        'name' => 'That file is named like something else on this device.',
        'unreadable' => 'That file is not an update this device can read.',
        _ => 'That update cannot be installed on this device.',
      };

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
    // BlueZ
    if (name == 'org.bluez.Error.Blocked') return 'Bluetooth is switched off. Turn it on first.';
    if (name == 'org.bluez.Error.NotReady') return 'Bluetooth is still starting. Try again in a moment.';
    if (name == 'org.bluez.Error.AuthenticationCanceled' || name == 'org.bluez.Error.AuthenticationRejected') {
      return 'The pairing was canceled.';
    }
    if (name == 'org.bluez.Error.DoesNotExist') return 'That device is no longer paired.';
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

  /// What ALSA's tools (arecord, aplay) said on stderr, for a person.
  static String audio(String toolMessage) {
    final m = toolMessage.toLowerCase();
    if (m.contains('no space left')) return 'There is no room left. The recording stops there.';
    if (m.contains('no such device') || m.contains('audio open error') || m.contains('unable to install hw params')) {
      return 'The microphone or speaker is not answering.';
    }
    if (m.contains('device or resource busy')) return 'Another applet is using the sound device.';
    if (m.contains('input/output error')) return 'The sound device stopped. The recording may end early.';
    return failed;
  }

  // The camera's sentences (plan 0018 D14; the notices evrx-rt's Camera
  // said, in the same words, plus the ones a hot-plugged camera adds).

  /// camerad found nothing to open.
  static const cameraNone = 'No camera was found.';

  /// No camera is listed at all (the empty screen's line).
  static const cameraNotConnected = 'No camera is connected.';

  /// The build named a camera port and nothing answered on it.
  static const cameraExpectedMissing =
      'A camera was expected on the camera port and none answered. A camera connects when the device starts.';

  /// A second app has the viewfinder.
  static const cameraInUse = 'Another app is using the camera.';
  static const cameraStartFailed = 'The camera did not start.';

  /// A webcam was unplugged, or camerad ended the stream.
  static const cameraDisconnected = 'The camera was disconnected.';

  /// Settings > Camera is Off.
  static const cameraOff = 'The camera is switched off in Settings.';
  static const photoNoRoom = 'The photo was not saved: there is no room left.';
  static const photoSaveFailed = 'The photo was not saved. Check that the card is in.';
  static const photoFolderFull = 'The photo was not saved: the folder holds 9999 photos.';
  static const photoAsked = 'Sent to the assistant.';
  static const photoNobody = 'No app on this device can look at photos yet.';
  static const photoAskFailed = 'The photo could not be sent. Try again.';

  /// camerad's reason for an empty list, for a person.
  static String cameraReason(String reason) => switch (reason) {
        'expected-csi-missing' => cameraExpectedMissing,
        'disabled' => cameraOff,
        _ => cameraNotConnected,
      };

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
