import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

/// The bridge's wire on the applet side: Varlink frames split on NUL as
/// bytes arrive, and Listen replies read as deliveries.
void main() {
  test('frames come out whole however the bytes arrive', () {
    final frames = VarlinkFrames();
    final bytes = '{"parameters":{"kind":"intent","id":3,"name":"vrx.open","payload":{"a":1}},"continues":true}\u0000{"par'.codeUnits;
    final first = frames.add(bytes);
    expect(first, hasLength(1));
    expect((first.single['parameters'] as Map)['id'], 3);
    expect(frames.add('ameters":{}}\u0000'.codeUnits), [
      {'parameters': <String, dynamic>{}}
    ]);
  });

  test('a Listen reply is an intent to answer, or a channel with its stream', () {
    final told = deliveryOf({
      'parameters': {'kind': 'intent', 'id': 7, 'name': 'vrx.open', 'payload': null}
    }, () => null);
    expect(told, isA<VrxIntentDelivery>().having((d) => d.id, 'id', 7).having((d) => d.name, 'name', 'vrx.open'));
    final opened = deliveryOf({
      'parameters': {'kind': 'intent', 'name': 'sys.alarm.ring', 'payload': {'id': 2}}
    }, () => null);
    expect(opened, isA<VrxIntentDelivery>().having((d) => d.id, 'id', isNull), reason: 'an opened handler is told; no answer');
    // a channel without its descriptor is dropped rather than half-made
    expect(deliveryOf({'parameters': {'kind': 'channel', 'from': 'mic', 'channel': 'samples'}}, () => null), isNull);
    expect(deliveryOf({'parameters': {'kind': 'other'}}, () => null), isNull);
  });
}
