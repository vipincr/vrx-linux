import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

/// The bridge's wire on the applet side: Varlink frames split on NUL as
/// bytes arrive, and Listen replies read as deliveries.
void main() {
  // The RawSocket rewrite is what makes an Open reply's descriptor
  // usable: a ResourceHandle.toSocket() Socket never flushed a write
  // (bench 2026-10-22, disp28a — the camera applet's captures never
  // reached camerad while root callers on the same channel worked). A
  // host test can only pass a made socket; the descriptor path itself
  // is proven on a board, by a capture from the viewfinder.
  test('a channel writes its records to the peer, whole lines', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final far = server.first;
    final near =
        await RawSocket.connect(InternetAddress.loopbackIPv4, server.port);
    final channel = VrxChannel('camerad.photos', near);
    final other = await far;
    await server.close();
    final said = Completer<String>();
    other.listen((d) {
      if (!said.isCompleted) said.complete(utf8.decode(d));
    });
    channel.write({'op': 'list'});
    final line = await said.future.timeout(const Duration(seconds: 2));
    expect(line.endsWith('\n'), isTrue, reason: 'the record is one whole line');
    expect((jsonDecode(line) as Map)['record']['op'], 'list');
    expect((jsonDecode(line) as Map)['pipe'], 'camerad.photos');
    channel.close();
    await other.close();
  });

  test('frames come out whole however the bytes arrive', () {
    final frames = VarlinkFrames();
    final bytes =
        '{"parameters":{"kind":"intent","id":3,"name":"vrx.open","payload":{"a":1}},"continues":true}\u0000{"par'
            .codeUnits;
    final first = frames.add(bytes);
    expect(first, hasLength(1));
    expect((first.single['parameters'] as Map)['id'], 3);
    expect(frames.add('ameters":{}}\u0000'.codeUnits), [
      {'parameters': <String, dynamic>{}}
    ]);
  });

  test('a Listen reply is an intent to answer, or a channel with its stream',
      () {
    final told = deliveryOf({
      'parameters': {
        'kind': 'intent',
        'id': 7,
        'name': 'vrx.open',
        'payload': null
      }
    }, () => null);
    expect(
        told,
        isA<VrxIntentDelivery>()
            .having((d) => d.id, 'id', 7)
            .having((d) => d.name, 'name', 'vrx.open'));
    final opened = deliveryOf({
      'parameters': {
        'kind': 'intent',
        'name': 'sys.alarm.ring',
        'payload': {'id': 2}
      }
    }, () => null);
    expect(opened, isA<VrxIntentDelivery>().having((d) => d.id, 'id', isNull),
        reason: 'an opened handler is told; no answer');
    // a channel without its descriptor is dropped rather than half-made
    expect(
        deliveryOf({
          'parameters': {'kind': 'channel', 'from': 'mic', 'channel': 'samples'}
        }, () => null),
        isNull);
    expect(
        deliveryOf({
          'parameters': {'kind': 'other'}
        }, () => null),
        isNull);
  });
}
