import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_check/vrx_check.dart';
import 'package:vrx_kit/vrx_kit.dart';

import 'package:camera_applet/main.dart';
import 'package:camera_applet/state.dart';

/// A texture that never reaches a plugin: the picture is a plain box.
class _Fake implements CameraTexture {
  @override
  Stream<({int textureId, String reason})> get ended => const Stream.empty();

  @override
  Future<CameraStream> open() async => const CameraStream(textureId: 1, width: 640, height: 480);

  @override
  Future<void> close(int textureId) async {}
}

const _csi =
    CameraInfo(id: 'csi0', kind: 'csi', name: 'IMX219 (Camera Module 2)', location: 'back', width: 3280, height: 2464);
const _usb = CameraInfo(id: 'usb1', kind: 'usb', name: 'Logitech Webcam C270', width: 1280, height: 720);

CameraState _listed(List<CameraInfo> cameras, {String reason = 'ok', bool enabled = true}) =>
    CameraState(known: true, enabled: enabled, cameras: cameras, reason: reason);

/// The Camera holds on every display vrx drives (vrx_check): every screen
/// it has, with real words in them (plan 0018 D14).
void main() {
  setUpAll(() => VrxCamera.install(_Fake()));

  CameraModel live({List<CameraInfo> cameras = const [_usb]}) {
    final m = CameraModel()
      ..reduce(const CameraSnapshot(), CameraListed(_listed(cameras)))
      ..reduce(const CameraSnapshot(), CameraAction.enter);
    m.reduce(const CameraSnapshot(), CameraStarted(m.gen, 640, 480));
    return m;
  }

  CameraModel saved() {
    final m = live();
    m.reduce(const CameraSnapshot(), CameraAction.capture);
    m.reduce(const CameraSnapshot(), CameraSaved(m.gen, path: 'IMG_0042.JPG'));
    return m;
  }

  final cases = <String, CameraModel Function()>{
    'live': live,
    'live with two cameras': () => live(cameras: const [_csi, _usb]),
    'starting': () => CameraModel()
      ..reduce(const CameraSnapshot(), CameraListed(_listed(const [_usb])))
      ..reduce(const CameraSnapshot(), CameraAction.enter),
    'not yet read': () => CameraModel()..reduce(const CameraSnapshot(), CameraAction.enter),
    'saving': () => live()..reduce(const CameraSnapshot(), CameraAction.capture),
    'a photo saved': saved,
    'sent to the assistant': () => saved()
      ..reduce(const CameraSnapshot(), CameraAction.ask)
      ..reduce(const CameraSnapshot(), const CameraAsked('handled')),
    'nobody can look': () => saved()
      ..reduce(const CameraSnapshot(), CameraAction.ask)
      ..reduce(const CameraSnapshot(), const CameraAsked('pass')),
    'folder full': () {
      final m = live();
      m.reduce(const CameraSnapshot(), CameraAction.capture);
      m.reduce(const CameraSnapshot(), CameraSaved(m.gen, code: 'folder-full'));
      return m;
    },
    'in use by another app': () {
      final m = CameraModel()
        ..reduce(const CameraSnapshot(), CameraListed(_listed(const [_usb])))
        ..reduce(const CameraSnapshot(), CameraAction.enter);
      m.reduce(const CameraSnapshot(), CameraStartFailed(m.gen, 'busy'));
      return m;
    },
    'disconnected': () {
      final m = live();
      m.reduce(const CameraSnapshot(), CameraEnded(m.gen));
      return m;
    },
    'no camera': () => CameraModel()
      ..reduce(const CameraSnapshot(), CameraListed(_listed(const [], reason: 'none-found')))
      ..reduce(const CameraSnapshot(), CameraAction.enter),
    'a camera expected on the port': () => CameraModel()
      ..reduce(const CameraSnapshot(), CameraListed(_listed(const [], reason: 'expected-csi-missing')))
      ..reduce(const CameraSnapshot(), CameraAction.enter),
    'switched off': () => CameraModel()
      ..reduce(const CameraSnapshot(), CameraListed(_listed(const [_usb], reason: 'disabled', enabled: false)))
      ..reduce(const CameraSnapshot(), CameraAction.enter),
  };
  for (final display in allDisplays) {
    for (final c in cases.entries) {
      testWidgets('camera ${c.key} on ${display.name}', (tester) async {
        await expectCleanLayout(
            tester, CameraApplet(c.value(), photos: CameraPhotos(open: () => Completer<VrxChannel>().future)),
            display: display);
      });
    }
  }
}
