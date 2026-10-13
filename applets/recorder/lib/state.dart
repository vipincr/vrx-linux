import 'dart:typed_data';

import 'package:vrx_kit/vrx_kit.dart';

enum RecorderAction { init, listed, recording, stopped, playing, failed, tick, level, opened }

/// The longest take (arecord's -d): an hour, said when it is reached.
const takeLimitSeconds = 3600;

class Recording {
  const Recording({required this.name, required this.seconds, this.bytes = 0, this.format = ''});

  final String name;
  final double seconds;
  final int bytes;

  /// "44.1 kHz, mono, 16-bit" from its header.
  final String format;
}

/// arecord's VU meter (`-V mono`) from what it wrote to stderr: the last
/// "| NN%" (or "| MAX") in [chunk], or null when the chunk has none.
int? meterPercent(String chunk) {
  final all = RegExp(r'\|\s*(MAX|\d+)%?').allMatches(chunk).toList();
  if (all.isEmpty) return null;
  final v = all.last.group(1)!;
  return v == 'MAX' ? 100 : int.parse(v).clamp(0, 100);
}

/// A WAV header's format, for a person ("44.1 kHz, mono, 16-bit").
String wavFormat(Uint8List head) {
  if (head.length < 44) return '';
  final b = ByteData.sublistView(head);
  final channels = b.getUint16(22, Endian.little);
  final rate = b.getUint32(24, Endian.little);
  final bits = b.getUint16(34, Endian.little);
  final khz = rate % 1000 == 0 ? '${rate ~/ 1000}' : (rate / 1000).toStringAsFixed(1);
  return '$khz kHz, ${channels == 1 ? 'mono' : channels == 2 ? 'stereo' : '$channels channels'}, $bits-bit';
}

/// "1.2 MB", "340 kB".
String sizeText(int bytes) =>
    bytes >= 1000000 ? '${(bytes / 1000000).toStringAsFixed(1)} MB' : '${(bytes / 1000).ceil()} kB';

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
  const RecorderView({
    required this.devices,
    required this.recordings,
    required this.recording,
    required this.playing,
    required this.elapsed,
    required this.error,
    this.level = 0,
    this.opened,
  });

  final SoundDevices devices;
  final List<Recording> recordings;
  final bool recording;

  /// The recording being played, or null.
  final String? playing;
  final double elapsed;
  final String? error;

  /// The input level while recording, 0-100.
  final int level;

  /// The take whose screen is open, or null.
  final Recording? opened;
}

class RecorderModel extends StoreModel<RecorderState, RecorderAction, RecorderView> {
  SoundDevices devices = const SoundDevices(playback: false, capture: false);
  List<Recording> recordings = const [];
  bool recording = false;
  String? playing;
  double elapsed = 0;
  String? error;
  int level = 0;

  /// The take whose screen is open (its name).
  String? opened;

  @override
  RecorderState get initial => const RecorderState();

  @override
  RecorderAction get bootAction => RecorderAction.init;

  @override
  RecorderView reduce(RecorderState state, RecorderAction action) {
    if (action == RecorderAction.opened) error = null;
    final shown = [for (final r in recordings) if (r.name == opened) r];
    // a take deleted (or gone) closes its screen
    if (shown.isEmpty) opened = null;
    return RecorderView(
      devices: devices,
      recordings: recordings,
      recording: recording,
      playing: playing,
      elapsed: elapsed,
      error: error,
      level: recording ? level : 0,
      opened: shown.isEmpty ? null : shown.first,
    );
  }

  @override
  RecorderState get snapshot => const RecorderState();
}

class RecorderState {
  const RecorderState();
}
