import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

import 'package:camera_applet/state.dart';

CameraState _state({List<CameraInfo>? cameras, bool enabled = true, String reason = 'ok'}) =>
    CameraState(known: true, enabled: enabled, cameras: cameras ?? const [_usb], reason: reason);

const _csi = CameraInfo(id: 'csi0', kind: 'csi', name: 'imx219', location: 'back', width: 3280, height: 2464);
const _usb = CameraInfo(id: 'usb1', kind: 'usb', name: 'Webcam', width: 1280, height: 720);

/// A live session in front, one camera listed: the starting point of most rows.
StoreHarness<CameraSnapshot, CameraAction, CameraView> _live({List<CameraInfo> cameras = const [_usb]}) {
  final h = StoreHarness(CameraModel())
    ..dispatch(CameraListed(CameraState(known: true, cameras: cameras, reason: 'ok')))
    ..dispatch(CameraAction.enter);
  h.dispatch(CameraStarted(h.view.gen, 640, 480));
  return h;
}

void main() {
  // a fresh test isolate compiles the reducer's pattern switch on its first
  // action; the device runs AOT, which has no such first call: warm it once
  setUpAll(() => CameraModel()
    ..reduce(const CameraSnapshot(), CameraAction.enter)
    ..reduce(const CameraSnapshot(), const CameraEnded(0)));

  test(
      'entering starts a session once a camera is listed; leaving ends it and refuses what was in flight (the generation rule)',
      () {
    final h = StoreHarness(CameraModel());
    h.dispatch(CameraAction.enter);
    h.assertView((v) => v.phase == CameraPhase.off && !v.mount && v.message == 'Starting the camera.',
        because: 'the list has not been read: nothing to open yet, and no empty state flashed');
    h.dispatch(CameraListed(_state(cameras: const [_usb])));
    h.assertView((v) => v.phase == CameraPhase.starting && v.mount,
        because: 'a camera is listed and the applet is in front');
    final gen = h.view.gen;
    h.dispatch(CameraStarted(gen + 1, 640, 480));
    h.assertView((v) => v.phase == CameraPhase.starting, because: 'another session\'s fact is refused');
    h.dispatch(CameraStarted(gen, 0, 480));
    h.assertView((v) => v.phase == CameraPhase.starting, because: 'a picture of no width is refused');
    h.dispatch(CameraStarted(gen, 640, 480));
    h.assertView((v) => v.live && v.canCapture && v.message == 'Ready.' && (v.w, v.h) == (640, 480));
    h.dispatch(CameraAction.leave);
    h.assertView((v) => v.phase == CameraPhase.off && !v.mount && !v.canCapture,
        because: 'the viewfinder is unmounted: the channel closes');
    h.dispatch(CameraStarted(gen, 640, 480));
    h.assertView((v) => v.phase == CameraPhase.off, because: 'a late Started from the ended session changes nothing');
    h.dispatch(CameraAction.enter);
    h.assertView((v) => v.phase == CameraPhase.starting && v.gen > gen, because: 'coming back is a new session');
  });

  test('a refused start is said in evrx\'s words, and Try again begins a new session', () {
    final h = StoreHarness(CameraModel())
      ..dispatch(CameraListed(_state()))
      ..dispatch(CameraAction.enter);
    final cases = {
      'unavailable': 'No camera was found.',
      'busy': 'Another app is using the camera.',
      'failed': 'The camera did not start.',
      'disabled': 'The camera is switched off in Settings.',
    };
    for (final c in cases.entries) {
      h.dispatch(CameraStartFailed(h.view.gen, c.key));
      h.assertView(
          (v) => v.phase == CameraPhase.failed && v.retry && v.message == c.value && v.signal == VrxSignal.error,
          because: c.key);
      h.dispatch(CameraAction.retry);
      h.assertView((v) => v.phase == CameraPhase.starting && v.message == 'Starting the camera.');
    }
    h.dispatch(CameraAction.retry);
    h.assertView((v) => v.phase == CameraPhase.starting, because: 'Try again from anywhere but failed is refused');
    h.dispatch(CameraAction.leave);
    h.dispatch(CameraStartFailed(h.view.gen, 'busy'));
    h.assertView((v) => v.phase == CameraPhase.off, because: 'a failure of an ended session is late');
  });

  test('a photo: Take photo needs a live picture, one at a time; success names the file, failures say why', () {
    final h = StoreHarness(CameraModel());
    h.dispatch(CameraAction.capture);
    h.assertView((v) => !v.saving, because: 'nothing to capture before the camera runs');
    h
      ..dispatch(CameraListed(_state()))
      ..dispatch(CameraAction.enter);
    h.dispatch(CameraAction.capture);
    h.assertView((v) => !v.saving, because: 'starting is not live');
    h.dispatch(CameraStarted(h.view.gen, 640, 480));
    final gen = h.view.gen;
    h.dispatch(CameraAction.capture);
    h.assertView((v) => v.saving && !v.canCapture && !v.canAsk && v.message == 'Saving the photo.');
    h.dispatch(CameraAction.capture);
    h.assertView((v) => v.saving, because: 'a second photo while one is saved is refused');
    h.dispatch(CameraSaved(gen + 7, path: 'IMG_0001.JPG'));
    h.assertView((v) => v.saving, because: 'another session\'s save is refused');
    h.dispatch(CameraSaved(gen, path: 'IMG_0042.JPG'));
    h.assertView((v) =>
        !v.saving &&
        v.canCapture &&
        v.canAsk &&
        v.message == 'Saved as IMG_0042.JPG.' &&
        v.signal == VrxSignal.success);
    final failures = {
      'no-room': 'The photo was not saved: there is no room left.',
      'folder-full': 'The photo was not saved: the folder holds 9999 photos.',
      'failed': 'The photo was not saved. Check that the card is in.',
      'too-large': 'The photo was not saved. Check that the card is in.',
      'busy': 'Another app is using the camera.',
    };
    for (final f in failures.entries) {
      h.dispatch(CameraAction.capture);
      h.dispatch(CameraSaved(gen, code: f.key));
      h.assertView((v) => v.message == f.value && v.signal == VrxSignal.error && v.saved == 'IMG_0042.JPG',
          because: f.key);
    }
  });

  test('leaving while a photo is saved waits for it; coming back before it lands keeps going', () {
    final h = _live();
    final gen = h.view.gen;
    h.dispatch(CameraAction.capture);
    h.dispatch(CameraAction.leave);
    h.assertView((v) => v.phase == CameraPhase.live && v.saving && v.mount && !v.canCapture,
        because: 'the stop waits for the photo');
    h.dispatch(CameraAction.enter);
    h.assertView((v) => v.canCapture == false && v.mount, because: 'back before the photo finished: keep going');
    h.dispatch(CameraSaved(gen, path: 'IMG_0001.JPG'));
    h.assertView((v) => v.live && v.canCapture && v.mount, because: 'nothing was waiting to stop');
    h.dispatch(CameraAction.capture);
    h.dispatch(CameraAction.leave);
    h.dispatch(CameraSaved(gen, path: 'IMG_0002.JPG'));
    h.assertView((v) => v.phase == CameraPhase.off && !v.mount && v.saved == 'IMG_0002.JPG',
        because: 'the photo landed, then the camera was let go');
  });

  test('Ask the assistant needs a photo; handled, nobody and failed are each said; the send belongs to no session', () {
    final h = _live();
    h.dispatch(CameraAction.ask);
    h.assertView((v) => !v.canAsk, because: 'no photo yet');
    h.dispatch(CameraAction.capture);
    h.dispatch(CameraSaved(h.view.gen, path: 'IMG_0001.JPG'));
    h.dispatch(const CameraAsked('handled'));
    h.assertView((v) => v.message != 'Sent to the assistant.', because: 'a verdict nobody asked for is refused');
    for (final c in {
      'handled': ('Sent to the assistant.', VrxSignal.success),
      'pass': ('No app on this device can look at photos yet.', VrxSignal.error),
      'failed': ('The photo could not be sent. Try again.', VrxSignal.error),
    }.entries) {
      h.dispatch(CameraAction.ask);
      h.assertView((v) => !v.canAsk, because: 'one send at a time');
      h.dispatch(CameraAsked(c.key));
      h.assertView((v) => v.message == c.value.$1 && v.signal == c.value.$2 && v.canAsk, because: c.key);
    }
    // a send that lands after the applet left still lands: it is no session's
    h.dispatch(CameraAction.ask);
    h.dispatch(CameraAction.leave);
    h.dispatch(const CameraAsked('handled'));
    h.assertView((v) => v.message == 'Sent to the assistant.');
  });

  test(
      'a webcam unplugged: the stream ends, the screen says so, Try again is offered, and plugging it back in starts again',
      () {
    final h = _live();
    final gen = h.view.gen;
    h.dispatch(CameraEnded(gen + 3));
    h.assertView((v) => v.live, because: 'another session\'s end is refused');
    h.dispatch(CameraEnded(gen));
    h.assertView(
        (v) => v.phase == CameraPhase.failed && !v.mount && v.message == 'The camera was disconnected.' && v.retry);
    h.dispatch(CameraListed(_state(cameras: const [], reason: 'none-found')));
    h.assertView((v) => v.empty && v.message == 'No camera is connected.' && !v.retry && v.cameras.isEmpty,
        because: 'camerad lists nothing: the empty state, no Try again');
    h.dispatch(CameraListed(_state(cameras: const [_usb])));
    h.assertView((v) => v.phase == CameraPhase.starting && v.mount,
        because: 'a camera back while in front: a new session');
  });

  test('the list emptying under a running session ends it; Settings Off says so', () {
    final h = _live();
    h.dispatch(CameraListed(_state(cameras: const [_usb], enabled: false, reason: 'disabled')));
    h.assertView(
        (v) => v.phase == CameraPhase.failed && v.empty && v.message == 'The camera is switched off in Settings.');
    h.dispatch(CameraAction.leave);
    h.dispatch(CameraAction.enter);
    h.assertView((v) => v.phase == CameraPhase.off && v.empty, because: 'off: nothing starts');
    h.dispatch(CameraListed(_state(cameras: const [_usb])));
    h.assertView((v) => v.phase == CameraPhase.starting, because: 'switched back On while in front');
  });

  test('no camera listed: the empty state names camerad\'s reason in words', () {
    final h = StoreHarness(CameraModel())..dispatch(CameraAction.enter);
    for (final r in {
      'none-found': 'No camera is connected.',
      'expected-csi-missing':
          'A camera was expected on the camera port and none answered. A camera connects when the device starts.',
      'disabled': 'The camera is switched off in Settings.',
    }.entries) {
      h.dispatch(CameraListed(_state(cameras: const [], reason: r.key, enabled: r.key != 'disabled')));
      h.assertView((v) => v.empty && !v.mount && v.message == r.value && v.phase == CameraPhase.off, because: r.key);
    }
    h.dispatch(const CameraListed(CameraState.absent));
    h.assertView((v) => v.empty && v.message == 'No camera is connected.', because: 'camerad not running: no camera');
  });

  test('two cameras: the switch row, picking one restarts the session and waits for camerad to confirm it', () {
    final h = _live(cameras: const [_csi, _usb]);
    h.assertView((v) => v.cameras.length == 2 && v.selected == 'csi0');
    final gen = h.view.gen;
    h.dispatch(const CameraPick('usb1'));
    h.assertView((v) => v.phase == CameraPhase.starting && v.gen > gen && v.selected == 'usb1' && !v.mount,
        because: 'camerad is told first: the viewfinder is not opened yet');
    h.dispatch(CameraStarted(h.view.gen, 640, 480));
    h.assertView((v) => v.phase == CameraPhase.starting, because: 'not before the select is confirmed');
    h.dispatch(CameraSelected(h.view.gen));
    h.assertView((v) => v.mount && v.phase == CameraPhase.starting);
    h.dispatch(CameraStarted(h.view.gen, 640, 480));
    h.assertView((v) => v.live);
    h.dispatch(const CameraPick('nope'));
    h.assertView((v) => v.selected == 'usb1', because: 'a camera camerad does not list is refused');
    h.dispatch(CameraListed(_state(cameras: const [_csi])));
    h.assertView((v) => v.selected == 'csi0' && v.cameras.length == 1,
        because: 'the picked camera went: back to the one left');
  });

  test(
      'a second applet\'s promise: every action from every state reduces, replays, restores and Backs out (plan 0013 D2)',
      () {
    final h = _live(cameras: const [_csi, _usb])
      ..dispatch(CameraAction.capture)
      ..dispatch(const CameraPick('usb1'))
      ..dispatch(CameraAction.leave);
    h.verify(
      fresh: CameraModel.new,
      probes: [
        CameraAction.init,
        CameraAction.enter,
        CameraAction.leave,
        CameraAction.capture,
        CameraAction.ask,
        CameraAction.retry,
        CameraAction.back,
        const CameraStarted(1, 640, 480),
        const CameraStartFailed(1, 'busy'),
        const CameraEnded(1),
        const CameraSelected(1),
        const CameraSaved(1, path: 'IMG_0001.JPG'),
        const CameraSaved(1, code: 'no-room'),
        const CameraAsked('pass'),
        const CameraListed(CameraState.absent),
        const CameraPick('csi0'),
      ],
    );
  });
}
