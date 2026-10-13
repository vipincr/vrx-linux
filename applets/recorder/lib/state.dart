import 'dart:typed_data';

import 'package:vrx_kit/vrx_kit.dart';

enum RecorderAction { init, listed, recording, stopped, playing, failed, tick }

class Recording {
  const Recording({required this.name, required this.seconds});

  final String name;
  final double seconds;
}

/// What the board can do with sound, from /proc/asound/pcm.
class SoundDevices {
  const SoundDevices({required this.playback, required this.capture});

  final bool playback;
  final bool capture;

  /// /proc/asound/pcm lines: "00-00: name : name : playback 1 : capture 1".
  static SoundDevices parse(String pcm) => SoundDevices(
        playback: pcm.contains('playback'),
        capture: pcm.contains('capture'),
      );
}

/// A WAV file's length in seconds from its header: the data chunk's size
/// over the byte rate; 0 when the header is not one.
double wavSeconds(Uint8List head, int fileSize) {
  if (head.length < 44) return 0;
  final b = ByteData.sublistView(head);
  String tag(int at) => String.fromCharCodes(head.sublist(at, at + 4));
  if (tag(0) != 'RIFF' || tag(8) != 'WAVE') return 0;
  final rate = b.getUint32(28, Endian.little);
  if (rate == 0) return 0;
  // a header still being written says 0 or 0xffffffff: the file's size
  // stands in for the data chunk's
  var data = b.getUint32(40, Endian.little);
  if (data == 0 || data == 0xffffffff) data = fileSize - 44;
  return data / rate;
}

String mmss(double seconds) {
  final s = seconds.round();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

class RecorderView {
  const RecorderView({required this.devices, required this.recordings, required this.recording, required this.playing, required this.elapsed, required this.error});

  final SoundDevices devices;
  final List<Recording> recordings;
  final bool recording;

  /// The recording being played, or null.
  final String? playing;
  final double elapsed;
  final String? error;
}

class RecorderModel extends StoreModel<RecorderState, RecorderAction, RecorderView> {
  SoundDevices devices = const SoundDevices(playback: false, capture: false);
  List<Recording> recordings = const [];
  bool recording = false;
  String? playing;
  double elapsed = 0;
  String? error;

  @override
  RecorderState get initial => const RecorderState();

  @override
  RecorderAction get bootAction => RecorderAction.init;

  @override
  RecorderView reduce(RecorderState state, RecorderAction action) => RecorderView(
        devices: devices,
        recordings: recordings,
        recording: recording,
        playing: playing,
        elapsed: elapsed,
        error: error,
      );

  @override
  RecorderState get snapshot => const RecorderState();
}

class RecorderState {
  const RecorderState();
}
