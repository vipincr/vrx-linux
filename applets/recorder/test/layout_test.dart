import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_check/vrx_check.dart';

import 'package:recorder_applet/main.dart';
import 'package:recorder_applet/state.dart';

/// The Recorder holds on every display vrx drives (vrx_check), with and
/// without a microphone, idle and recording.
void main() {
  const recordings = [
    Recording(name: 'rec-20261013-150412.wav', seconds: 12.4, bytes: 1093764, format: '44.1 kHz, mono, 16-bit'),
    Recording(name: 'rec-20261013-091530.wav', seconds: 3605),
  ];
  final cases = <String, RecorderModel Function()>{
    'mic': () => RecorderModel()
      ..devices = const SoundDevices(playback: true, capture: true)
      ..recordings = recordings,
    'no mic': () => RecorderModel()
      ..devices = const SoundDevices(playback: true, capture: false)
      ..recordings = recordings,
    'silent': () => RecorderModel()..recordings = recordings,
    'recording': () => RecorderModel()
      ..devices = const SoundDevices(playback: true, capture: true)
      ..recording = true
      ..elapsed = 75
      ..level = 63
      ..recordings = recordings,
    'a take': () => RecorderModel()
      ..devices = const SoundDevices(playback: true, capture: true)
      ..recordings = recordings
      ..opened = recordings.first.name,
    'a take playing': () => RecorderModel()
      ..devices = const SoundDevices(playback: true, capture: true)
      ..recordings = recordings
      ..opened = recordings.first.name
      ..playing = recordings.first.name
      ..elapsed = 4,
  };
  for (final display in allDisplays) {
    for (final c in cases.entries) {
      testWidgets('recorder ${c.key} on ${display.name}', (tester) async {
        await expectCleanLayout(tester, RecorderApplet(c.value()), display: display);
      });
    }
  }
}
