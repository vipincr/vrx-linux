import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:recorder_applet/state.dart';
import 'package:vrx_kit/vrx_kit.dart';

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

  // plan 0011 D11: arecord's own VU meter is the level bar
  test("arecord's meter reads as a level; other stderr does not", () {
    // captured from `arecord -V mono`: carriage returns, a bar, a percent
    const chunk = '\r#####                                             | 09%\r##########+                                       | 21%';
    expect(meterPercent(chunk), 21);
    expect(meterPercent('\r##################################################| MAX'), 100);
    expect(meterPercent('arecord: main:850: audio open error: No such device'), isNull);
  });

  test("a take's format and size read for a person", () {
    final head = Uint8List(44);
    final b = ByteData.sublistView(head);
    head.setAll(0, 'RIFF'.codeUnits);
    head.setAll(8, 'WAVE'.codeUnits);
    b.setUint16(22, 1, Endian.little);
    b.setUint32(24, 44100, Endian.little);
    b.setUint32(28, 88200, Endian.little);
    b.setUint16(34, 16, Endian.little);
    expect(wavFormat(head), '44.1 kHz, mono, 16-bit');
    expect(sizeText(1093764), '1.1 MB');
    expect(sizeText(340000), '340 kB');
  });

  test("ALSA's complaints are said for a person", () {
    expect(VrxWords.audio('arecord: pcm_write:2058: write error: No space left on device'), contains('no room left'));
    expect(VrxWords.audio('arecord: main:850: audio open error: No such device'), contains('not answering'));
  });
}
