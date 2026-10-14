// The sockets and the fake's controller live as long as their test; the tests
// close the channel end they own (a closed socket is what some of them check).
// ignore_for_file: close_sinks

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

const _two = '''{"enabled":true,"cameras":[
  {"id":"csi0","kind":"csi","name":"imx219","location":"back","max":[3280,2464]},
  {"id":"usb1","kind":"usb","name":"Webcam C270","location":"external","max":[1280,720]}],
  "active":true,"clients":1,"reason":"ok"}''';

/// A VrxChannel over a local socket, the other end in the test's hands.
Future<(VrxChannel, Socket)> _pair() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final far = server.first;
  final near = await Socket.connect(InternetAddress.loopbackIPv4, server.port);
  final other = await far;
  await server.close();
  return (VrxChannel('camerad.photos', near), other);
}

class _FakeTexture implements CameraTexture {
  _FakeTexture({this.fail});

  final CameraError? fail;
  final closed = <int>[];
  final endedController = StreamController<({int textureId, String reason})>.broadcast();

  @override
  Stream<({int textureId, String reason})> get ended => endedController.stream;

  @override
  Future<CameraStream> open() async {
    if (fail != null) throw fail!;
    return const CameraStream(textureId: 7, width: 640, height: 480);
  }

  @override
  Future<void> close(int textureId) async => closed.add(textureId);
}

void main() {
  test('the state file is read as documented, and anything else is no camera', () {
    final s = CameraState.parse(_two);
    expect(s.known && s.enabled && s.active, isTrue);
    expect(s.cameras.map((c) => c.id), ['csi0', 'usb1']);
    expect((s.cameras[0].width, s.cameras[0].height, s.cameras[0].location), (3280, 2464, 'back'));
    expect((s.clients, s.reason), (1, 'ok'));
    for (final bad in ['', 'nonsense', '[1,2]', '{"cameras":"no"}x']) {
      expect(CameraState.parse(bad), CameraState.absent, reason: bad);
    }
    expect(CameraState.parse('{"enabled":false,"cameras":[],"active":false,"clients":0,"reason":"disabled"}').enabled,
        isFalse);
    expect(CameraState.parse(_two), CameraState.parse(_two), reason: 'a repeat is equal');
  });

  test('the service says the state now, again on a change, and survives camerad coming and going', () async {
    final root = Directory.systemTemp.createTempSync('vrx-camera');
    final dir = '${root.path}/camera';
    final service = CameraService(dir: dir);
    final seen = <CameraState>[];
    final sub = service.watch().listen(seen.add);
    Future<void> until(bool Function() ok) async {
      for (var i = 0; i < 100 && !ok(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    await until(() => seen.isNotEmpty);
    expect(seen.single, CameraState.absent, reason: 'camerad is not running');
    // camerad starts: its directory, then its file (written whole, renamed in)
    Directory(dir).createSync();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    File('$dir/.state.json.new').writeAsStringSync(_two);
    File('$dir/.state.json.new').renameSync('$dir/state.json');
    await until(() => seen.length >= 2 && seen.last.active);
    expect(seen.last.cameras, hasLength(2));
    expect(seen.last.active, isTrue);
    // it stops: the directory goes with the unit, and nothing is left active
    Directory(dir).deleteSync(recursive: true);
    await until(() => !seen.last.known);
    expect(seen.last, CameraState.absent);
    await sub.cancel();
    root.deleteSync(recursive: true);
  });

  test('a photo request goes out with fd false, is matched by id, and an error is thrown by name', () async {
    final (channel, far) = await _pair();
    final photos = CameraPhotos(open: () async => channel);
    final lines = utf8.decoder.bind(far).transform(const LineSplitter()).asBroadcastStream();
    final first = lines.first;
    final shot = photos.capture(quality: 70);
    final request = (jsonDecode(await first) as Map<String, dynamic>)['record'] as Map<String, dynamic>;
    expect(
        request, {'op': 'capture', 'camera': null, 'width': null, 'quality': 70, 'keep': true, 'fd': false, 'id': 1});
    far.write('${jsonEncode({
          'pipe': 'camerad.photos',
          'record': {
            'id': 1,
            'ok': true,
            'bytes': 1234,
            'width': 640,
            'height': 480,
            'mime': 'image/jpeg',
            'path': 'IMG_0042.JPG'
          }
        })}\n');
    final done = await shot;
    expect((done.path, done.bytes, done.width), ('IMG_0042.JPG', 1234, 640));

    final second = lines.first;
    final failing = photos.capture();
    await second;
    far.write('${jsonEncode({
          'pipe': 'camerad.photos',
          'record': {'id': 2, 'ok': false, 'error': 'folder-full'}
        })}\n');
    await expectLater(failing, throwsA(isA<CameraError>().having((e) => e.code, 'code', 'folder-full')));

    // the channel closing fails what was waiting, by name
    final third = lines.first;
    final lost = photos.list();
    await third;
    await far.close();
    await expectLater(lost, throwsA(isA<CameraError>().having((e) => e.code, 'code', 'failed')));
    photos.close();
  });

  test('a channel that cannot be opened is unavailable', () async {
    final photos = CameraPhotos(open: () async => throw const VarlinkError('io.vrx.Host.NotListening', {}));
    await expectLater(photos.capture(), throwsA(isA<CameraError>().having((e) => e.code, 'code', 'unavailable')));
  });

  testWidgets('the view opens the stream when mounted and gives it back when disposed', (tester) async {
    final texture = _FakeTexture();
    CameraStream? started;
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: VrxCameraView(texture: texture, onStarted: (s) => started = s),
    ));
    await tester.pump();
    expect(started?.textureId, 7);
    expect(find.byType(Texture), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    expect(texture.closed, [7]);
  });

  testWidgets('a refused open and a stream camerad ended are each said once', (tester) async {
    final refused = _FakeTexture(fail: const CameraError('busy'));
    CameraError? error;
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: VrxCameraView(texture: refused, onFailed: (e) => error = e),
    ));
    await tester.pump();
    expect(error?.code, 'busy');
    expect(find.byType(Texture), findsNothing);

    final texture = _FakeTexture();
    String? ended;
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: VrxCameraView(key: const ValueKey('b'), texture: texture, onEnded: (r) => ended = r),
    ));
    await tester.pump();
    texture.endedController.add((textureId: 7, reason: 'producer-closed'));
    await tester.pump();
    await tester.pump();
    expect(ended, 'producer-closed');
    expect(find.byType(Texture), findsNothing);
  });
}
