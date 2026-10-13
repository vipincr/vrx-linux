import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:recorder_applet/state.dart';

Uint8List wavHeader({required int byteRate, required int dataSize}) {
  final b = ByteData(44);
  void tag(int at, String s) {
    for (var i = 0; i < 4; i++) {
      b.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  tag(8, 'WAVE');
  b.setUint32(28, byteRate, Endian.little);
  b.setUint32(40, dataSize, Endian.little);
  return b.buffer.asUint8List();
}

void main() {
  test('a WAV header gives the length; one still being written uses the file size', () {
    // 44.1 kHz mono 16-bit: 88200 bytes a second
    expect(wavSeconds(wavHeader(byteRate: 88200, dataSize: 88200 * 3), 0), 3);
    expect(wavSeconds(wavHeader(byteRate: 88200, dataSize: 0xffffffff), 44 + 88200 * 2), 2);
    expect(wavSeconds(Uint8List(10), 100), 0);
    expect(mmss(125.4), '2:05');
  });

  test('the devices come from /proc/asound/pcm', () {
    const hdmiOnly = '00-00: MAI PCM i2s-hifi-0 : MAI PCM i2s-hifi-0 : playback 1\n';
    expect(SoundDevices.parse(hdmiOnly).playback, isTrue);
    expect(SoundDevices.parse(hdmiOnly).capture, isFalse);
    expect(SoundDevices.parse('00-00: USB Audio : USB Audio : playback 1 : capture 1\n').capture, isTrue);
  });
}
