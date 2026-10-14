import 'package:vrx_kit/vrx_kit.dart';

// The Camera model, ported from evrx-rt's camera_model.c (plan 0018 D14).
// What carries over unchanged is the reducer's discipline: phases OFF,
// STARTING, LIVE, FAILED; one generation counter that ends with each
// session, so a fact from a session that is over arrives late and is
// refused; a photo being saved holds a stop back until it lands; and the
// ten notices, in the same words.
//
// What does not carry over is the buffer ring (camera_ring.c, the Ready,
// Frame, NoFrame and Shown facts): evrx's view dequeued frames from a
// V4L2 device and gave each back after showing a later one. Here camerad
// owns the camera, the flutter-vrx plugin imports its dmabufs as a
// texture and gives every buffer back itself (plan 0009's queue), so the
// model never sees a frame. Its facts are the ones a session still has:
// Started (the texture exists), StartFailed, Ended (camerad closed the
// stream: a webcam was unplugged), Saved and Asked.

/// What the Camera reacts to (plan 0013 D1: the reducer is the only
/// writer): a signal, or what happened, as data.
sealed class CameraAction {
  const CameraAction();

  static const init = CameraSignal.init;
  static const enter = CameraSignal.enter;
  static const leave = CameraSignal.leave;
  static const capture = CameraSignal.capture;
  static const ask = CameraSignal.ask;
  static const retry = CameraSignal.retry;
  static const back = CameraSignal.back;
}

/// [enter]: the applet is in front. [leave]: it is not (home, another
/// applet, the screen off): the camera is let go. [capture] is Take
/// photo, [ask] Ask the assistant, [retry] Try again.
enum CameraSignal implements CameraAction { init, enter, leave, capture, ask, retry, back }

/// The viewfinder of session [gen] is up: the texture shows [w] by [h].
final class CameraStarted implements CameraAction {
  const CameraStarted(this.gen, this.w, this.h);

  final int gen;
  final int w, h;
}

/// The viewfinder of session [gen] did not open; [code] is the plugin's
/// (`busy`, `unavailable`, `disabled`, `failed`, ...).
final class CameraStartFailed implements CameraAction {
  const CameraStartFailed(this.gen, this.code);

  final int gen;
  final String code;
}

/// camerad ended session [gen]'s stream on its own.
final class CameraEnded implements CameraAction {
  const CameraEnded(this.gen);

  final int gen;
}

/// The camera named for session [gen] is chosen (camerad answered the
/// select); the viewfinder may open.
final class CameraSelected implements CameraAction {
  const CameraSelected(this.gen);

  final int gen;
}

/// A photo of session [gen] was saved ([path]: its name in the photo
/// folder) or was not ([code]: camerad's error).
final class CameraSaved implements CameraAction {
  const CameraSaved(this.gen, {this.path, this.code});

  final int gen;
  final String? path;
  final String? code;
}

/// The photo was sent: [verdict] is `handled`, `pass` (nobody takes it),
/// or `failed`. It belongs to no session.
final class CameraAsked implements CameraAction {
  const CameraAsked(this.verdict);

  final String verdict;
}

/// camerad's state file changed (the cameras, whether one runs, why not).
final class CameraListed implements CameraAction {
  const CameraListed(this.state);

  final CameraState state;
}

/// A camera was picked in the switch row.
final class CameraPick implements CameraAction {
  const CameraPick(this.id);

  final String id;
}

enum CameraPhase { off, starting, live, failed }

/// What the status line says went wrong (evrx's CAMERA_NOTICE_*, plus the
/// two a hot-plugged and switchable camera add).
enum CameraNotice {
  none,
  noCamera,
  inUse,
  startFailed,
  noRoom,
  saveFailed,
  folderFull,
  asked,
  nobody,
  askFailed,
  disconnected,
  off,
}

/// evrx's start_notice: a camera that is not there, one in use, any other
/// refusal.
CameraNotice startNotice(String code) => switch (code) {
      'unavailable' || 'no-camera' => CameraNotice.noCamera,
      'busy' => CameraNotice.inUse,
      'disabled' => CameraNotice.off,
      _ => CameraNotice.startFailed,
    };

/// evrx's save_notice: no room, a full folder, anything else.
CameraNotice saveNotice(String code) => switch (code) {
      'no-room' => CameraNotice.noRoom,
      'folder-full' => CameraNotice.folderFull,
      'no-camera' => CameraNotice.noCamera,
      'busy' => CameraNotice.inUse,
      'disabled' => CameraNotice.off,
      _ => CameraNotice.saveFailed,
    };

String? noticeText(CameraNotice n) => switch (n) {
      CameraNotice.none => null,
      CameraNotice.noCamera => VrxWords.cameraNone,
      CameraNotice.inUse => VrxWords.cameraInUse,
      CameraNotice.startFailed => VrxWords.cameraStartFailed,
      CameraNotice.noRoom => VrxWords.photoNoRoom,
      CameraNotice.saveFailed => VrxWords.photoSaveFailed,
      CameraNotice.folderFull => VrxWords.photoFolderFull,
      CameraNotice.asked => VrxWords.photoAsked,
      CameraNotice.nobody => VrxWords.photoNobody,
      CameraNotice.askFailed => VrxWords.photoAskFailed,
      CameraNotice.disconnected => VrxWords.cameraDisconnected,
      CameraNotice.off => VrxWords.cameraOff,
    };

/// The photo's name for a person: "Saved as IMG_0042.JPG."
String savedText(String name) => 'Saved as $name.';

class CameraView {
  const CameraView({
    required this.phase,
    required this.gen,
    required this.mount,
    required this.live,
    required this.saving,
    required this.canCapture,
    required this.canAsk,
    required this.retry,
    required this.message,
    required this.signal,
    required this.cameras,
    required this.selected,
    required this.empty,
    this.saved,
    this.w = 0,
    this.h = 0,
  });

  final CameraPhase phase;

  /// The session; the view keys the viewfinder by it.
  final int gen;

  /// The viewfinder is mounted (it opens the stream when it is, and
  /// releases it when it goes).
  final bool mount;

  /// Frames are showing.
  final bool live;
  final bool saving;
  final bool canCapture, canAsk;

  /// Try again is offered.
  final bool retry;
  final String message;
  final VrxSignal? signal;

  /// More than one: the switch row is offered.
  final List<CameraInfo> cameras;
  final String? selected;

  /// No camera is listed: the empty state shows, with [message] saying why.
  final bool empty;

  /// The last photo's name this session.
  final String? saved;
  final int w, h;
}

class CameraSnapshot {
  const CameraSnapshot({this.saved});

  final String? saved;

  @override
  bool operator ==(Object other) => other is CameraSnapshot && other.saved == saved;

  @override
  int get hashCode => saved.hashCode;
}

class CameraModel extends StoreModel<CameraSnapshot, CameraAction, CameraView> {
  CameraPhase phase = CameraPhase.off;

  /// Ends with every session (evrx's `gen`, a byte there; wide enough here).
  int gen = 0;
  bool inFront = false;
  bool saving = false;

  /// Left while a photo was being saved: the stop waits for it.
  bool stopAfter = false;
  bool asking = false;

  /// The viewfinder waits for camerad to confirm the camera picked.
  bool selecting = false;
  CameraNotice notice = CameraNotice.none;
  String? saved;
  int w = 0, h = 0;

  /// camerad's state, once it has been read.
  CameraState state = CameraState.absent;
  bool listed = false;

  /// The camera the person picked, and the one camerad has been told.
  String? picked;
  String? applied;

  bool get hasCamera => state.enabled && state.cameras.isNotEmpty;

  @override
  CameraSnapshot get initial => const CameraSnapshot();

  @override
  CameraAction get bootAction => CameraAction.init;

  /// A new session: the viewfinder is opened, off the model's task.
  void _begin() {
    phase = CameraPhase.starting;
    gen++;
    notice = CameraNotice.none;
    selecting = picked != null && picked != applied;
  }

  /// The session ends: the viewfinder is unmounted, which gives the
  /// stream back, and whatever was in flight is refused when it lands
  /// because its generation is over.
  void _end() {
    gen++;
    phase = CameraPhase.off;
    stopAfter = false;
    selecting = false;
    w = h = 0;
  }

  /// The camera went (unplugged, switched off): the session is over and
  /// the screen says why.
  void _lost(CameraNotice why) {
    gen++;
    phase = CameraPhase.failed;
    notice = why;
    selecting = false;
    w = h = 0;
  }

  @override
  CameraView reduce(CameraSnapshot snapshot, CameraAction action) {
    switch (action) {
      case CameraSignal.init:
        break;
      case CameraSignal.enter:
        inFront = true;
        if (stopAfter) {
          // back before the photo finished: keep going
          stopAfter = false;
        } else if (phase == CameraPhase.off && listed && hasCamera) {
          _begin();
        }
      case CameraSignal.leave:
        inFront = false;
        if (phase == CameraPhase.off || phase == CameraPhase.failed) {
          phase = CameraPhase.off;
        } else if (saving) {
          // the photo is being written: the stop waits for it
          stopAfter = true;
        } else {
          _end();
        }
      case CameraSignal.back:
        break;
      case CameraSignal.retry:
        if (phase == CameraPhase.failed && hasCamera) _begin();
      case CameraSignal.capture:
        if (phase == CameraPhase.live && !saving && !stopAfter) {
          saving = true;
          notice = CameraNotice.none;
        }
      case CameraSignal.ask:
        if (saved != null && !asking && !saving) {
          asking = true;
          notice = CameraNotice.none;
        }
      case CameraStarted(:final gen, :final w, :final h):
        // another session's, late, or not a session that is starting
        if (gen == this.gen && phase == CameraPhase.starting && !selecting && w > 0 && h > 0) {
          phase = CameraPhase.live;
          this.w = w;
          this.h = h;
        }
      case CameraSelected(:final gen):
        if (gen == this.gen && phase == CameraPhase.starting && selecting) {
          selecting = false;
          applied = picked;
        }
      case CameraStartFailed(:final gen, :final code):
        if (gen == this.gen && phase == CameraPhase.starting) {
          phase = CameraPhase.failed;
          selecting = false;
          notice = startNotice(code);
        }
      case CameraEnded(:final gen):
        if (gen == this.gen && phase == CameraPhase.live) _lost(CameraNotice.disconnected);
      case CameraSaved(:final gen, :final path, :final code):
        if (saving && gen == this.gen) {
          saving = false;
          if (code == null && path != null) {
            saved = path;
            notice = CameraNotice.none;
          } else {
            notice = saveNotice(code ?? 'failed');
          }
          if (stopAfter) _end();
        }
      case CameraAsked(:final verdict):
        // the send belongs to no session
        if (asking) {
          asking = false;
          notice = switch (verdict) {
            'handled' => CameraNotice.asked,
            'pass' => CameraNotice.nobody,
            _ => CameraNotice.askFailed,
          };
        }
      case CameraListed(state: final s):
        state = s;
        listed = true;
        if (picked != null && !s.cameras.any((c) => c.id == picked)) {
          picked = null;
          applied = null;
        }
        if (!hasCamera && (phase == CameraPhase.live || phase == CameraPhase.starting)) {
          // the list emptied under a running session
          _lost(!s.enabled ? CameraNotice.off : CameraNotice.disconnected);
        } else if (hasCamera &&
            inFront &&
            !stopAfter &&
            (phase == CameraPhase.off || (phase == CameraPhase.failed && notice == CameraNotice.disconnected))) {
          // a camera appeared (a webcam plugged in) while the screen waits
          _begin();
        }
      case CameraPick(:final id):
        if (state.cameras.any((c) => c.id == id) && id != (picked ?? state.cameras.first.id)) {
          picked = id;
          if (phase == CameraPhase.live || phase == CameraPhase.starting) {
            _end();
            if (inFront) _begin();
          }
        }
    }
    return _view();
  }

  CameraView _view() {
    final live = phase == CameraPhase.live;
    final text = noticeText(notice);
    String message;
    VrxSignal? signal;
    if (!hasCamera && (phase == CameraPhase.off || phase == CameraPhase.failed)) {
      // nothing to open: camerad's reason, in words
      message = listed ? VrxWords.cameraReason(state.enabled ? state.reason : 'disabled') : 'Starting the camera.';
      signal = listed ? VrxSignal.info : null;
    } else if (phase == CameraPhase.starting) {
      message = 'Starting the camera.';
    } else if (saving) {
      message = 'Saving the photo.';
    } else if (text != null) {
      message = text;
      signal = notice == CameraNotice.asked ? VrxSignal.success : VrxSignal.error;
    } else if (saved != null) {
      message = savedText(saved!);
      signal = VrxSignal.success;
    } else if (live) {
      message = 'Ready.';
    } else {
      message = '';
    }
    return CameraView(
      phase: phase,
      gen: gen,
      mount: (phase == CameraPhase.starting || live) && !selecting,
      live: live,
      saving: saving,
      canCapture: live && !saving && !stopAfter,
      canAsk: saved != null && !asking && !saving,
      retry: phase == CameraPhase.failed && hasCamera,
      message: message,
      signal: signal,
      cameras: state.cameras,
      selected: picked ?? (state.cameras.isEmpty ? null : state.cameras.first.id),
      empty: !hasCamera && !live && phase != CameraPhase.starting,
      saved: saved,
      w: w,
      h: h,
    );
  }

  @override
  CameraSnapshot get snapshot => CameraSnapshot(saved: saved);

  /// A restored applet has no session (the camera was let go); what it
  /// remembers is the last photo it took.
  @override
  void restore(CameraSnapshot snapshot) => saved = snapshot.saved;

  @override
  CameraAction get backAction => CameraAction.back;

  @override
  Object? get fingerprint =>
      [phase, gen, inFront, saving, stopAfter, asking, selecting, notice, saved, w, h, state, listed, picked, applied];
}
