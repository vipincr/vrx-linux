import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' hide Intent; // vrx's Intent
import 'package:vrx_kit/vrx_kit.dart';

import 'state.dart';

final _events = StreamController<RecorderAction>();

String get recordingsDir => '${Platform.environment['HOME'] ?? '/var/lib/vrx/recorder'}/recordings';

/// Recorder: WAV recordings through ALSA's arecord, played with aplay
/// (plan 0011 D11). arecord writes the file, header and length included,
/// and its VU meter (`-V mono`) on stderr is the level bar.
class RecorderApplet extends Applet<RecorderState, RecorderAction, RecorderView> {
  RecorderApplet(this.model);

  final RecorderModel model;
  Process? _process;
  VrxTicker? _clock;
  final _watch = Stopwatch();

  @override
  RecorderState get initial => model.initial;

  @override
  RecorderAction get bootAction => model.bootAction;

  @override
  RecorderView reduce(RecorderState state, RecorderAction action) => model.reduce(state, action);

  @override
  RecorderState get snapshot => model.snapshot;

  void _tick(bool on) {
    _clock?.cancel();
    if (!on) {
      _watch
        ..stop()
        ..reset();
      return;
    }
    _watch
      ..reset()
      ..start();
    // the elapsed time is whole seconds: once a second is the most it changes
    _clock = VrxTicker(const Duration(seconds: 1), () => _events.add(RecorderTick(_watch.elapsedMilliseconds / 1000)));
  }

  Future<void> _run(List<String> cmd, {required void Function() onEnd, bool meter = false}) async {
    try {
      final p = await Process.start(cmd.first, cmd.sublist(1));
      _process = p;
      final err = StringBuffer();
      p.stderr.listen((d) {
        final chunk = String.fromCharCodes(d);
        final level = meter ? meterPercent(chunk) : null;
        if (level != null) {
          if (level != model.level) _events.add(RecorderLevel(level));
          return;
        }
        err.write(chunk);
      });
      unawaited(p.stdout.drain<void>());
      final code = await p.exitCode;
      // a stop is SIGINT: arecord closes the file properly on it
      if (code != 0 && code != -2 && code != 130 && err.isNotEmpty) {
        debugPrint('recorder: ${cmd.first}: ${err.toString().trim()}');
        _events.add(RecorderError(VrxWords.audio(err.toString())));
      } else if (meter && model.elapsed >= takeLimitSeconds - 1) {
        _events.add(const RecorderError('Recordings stop at one hour.'));
      }
    } on Object catch (e) {
      _events.add(RecorderError(VrxWords.of(e, context: 'recorder: ${cmd.first}')));
    }
    _process = null;
    _tick(false);
    onEnd();
  }

  Future<void> record() async {
    if (_process != null) return;
    await Directory(recordingsDir).create(recursive: true);
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final name = 'rec-${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}${two(now.second)}.wav';
    _events.add(const RecorderStarted());
    _tick(true);
    await _run(
      ['arecord', '-f', 'S16_LE', '-r', '44100', '-c', '1', '-t', 'wav', '-V', 'mono', '-d', '$takeLimitSeconds', '$recordingsDir/$name'],
      meter: true,
      onEnd: () => _events.add(RecorderAction.stopped),
    );
    _events.add(RecorderListed(recordings: await listRecordings()));
  }

  Future<void> play(String name) async {
    if (_process != null) return;
    _events.add(RecorderStarted(play: name));
    _tick(true);
    await _run(['aplay', '-q', '$recordingsDir/$name'], onEnd: () => _events.add(RecorderAction.stopped));
  }

  void stop() => _process?.kill(ProcessSignal.sigint);

  Future<void> delete(String name) async {
    try {
      await File('$recordingsDir/$name').delete();
    } on FileSystemException catch (e) {
      _events.add(RecorderError(VrxWords.of(e, context: 'recorder: delete')));
    }
    _events.add(RecorderListed(recordings: await listRecordings()));
  }

  void _open(String? name) {
    _events.add(RecorderOpen(name));
  }

  @override
  Widget build(BuildContext context, RecorderView view) {
    final busy = view.recording || view.playing != null;
    final d = view.devices;
    final take = view.opened;
    if (take != null) {
      return Scaffold(
        body: SafeArea(
          child: Column(children: [
            Expanded(
              child: _Take(
                take: take,
                playing: view.playing == take.name,
                elapsed: view.elapsed,
                canPlay: d.playback && (!busy || view.playing == take.name),
                onBack: () => _open(null),
                onPlay: () => unawaited(play(take.name)),
                onStop: stop,
                onDelete: busy ? null : () => unawaited(_confirmDelete(context, take.name)),
              ),
            ),
            if (view.error != null) VrxBanner(text: view.error),
          ]),
        ),
      );
    }
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          const VrxHeader(title: 'Recorder', onBack: Nav.pop),
          if (busy)
            VrxRow(
              glyph: VrxSymbols.stop,
              label: view.recording ? 'Recording ${mmss(view.elapsed)}' : 'Playing ${mmss(view.elapsed)}',
              value: 'Stop',
              onTap: stop,
            )
          else if (d.capture)
            VrxRow(glyph: VrxSymbols.mic, label: 'Record', onTap: () => unawaited(record()))
          else
            const VrxRow(glyph: VrxSymbols.mic_off, label: 'No microphone on this device'),
          // the input level, as arecord's meter reads it
          if (view.recording) _Meter(level: view.level),
          if (!d.playback) const VrxRow(glyph: VrxSymbols.volume_off, label: 'No sound output on this device'),
          Expanded(
            child: ListView.builder(
              itemCount: view.recordings.length,
              itemBuilder: (context, i) {
                final r = view.recordings[i];
                // a tap opens the take; its hold deletes it (after asking)
                return VrxRow(
                  glyph: VrxSymbols.graphic_eq,
                  label: r.name.replaceAll('.wav', ''),
                  value: mmss(r.seconds),
                  onTap: () => _open(r.name),
                  onLongPress: busy ? null : () => unawaited(_confirmDelete(context, r.name)),
                );
              },
            ),
          ),
          if (view.error != null) VrxBanner(text: view.error),
        ]),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, String name) async {
    if (await vrxConfirm(context, title: 'Delete this recording?', message: '$name will be deleted.', act: 'Delete')) {
      unawaited(delete(name));
    }
  }
}

/// The level bar: how loud the input is, as arecord's meter says.
class _Meter extends StatelessWidget {
  const _Meter({required this.level});

  final int level;

  @override
  Widget build(BuildContext context) {
    final colors = VrxTheme.of(context);
    final s = ScaledSpacing.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: s.inset, vertical: s.sm),
      child: Semantics(
        label: 'Input level',
        value: '$level %',
        child: Container(
          height: s.sm,
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(color: colors.surfaceHigh, border: Border.all(color: colors.outline, width: Strokes.hairline)),
          child: FractionallySizedBox(widthFactor: level / 100, child: ColoredBox(color: colors.primary)),
        ),
      ),
    );
  }
}

/// One take: what it is, and what can be done with it.
class _Take extends StatelessWidget {
  const _Take({
    required this.take,
    required this.playing,
    required this.elapsed,
    required this.canPlay,
    required this.onBack,
    required this.onPlay,
    required this.onStop,
    required this.onDelete,
  });

  final Recording take;
  final bool playing;
  final double elapsed;
  final bool canPlay;
  final VoidCallback onBack, onPlay, onStop;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    return VrxList(children: [
      VrxHeader(title: take.name.replaceAll('.wav', ''), onBack: onBack),
      if (playing)
        VrxRow(glyph: VrxSymbols.stop, label: 'Playing ${mmss(elapsed)}', value: 'Stop', onTap: onStop)
      else
        VrxRow(glyph: VrxSymbols.play_arrow, label: 'Play', onTap: canPlay ? onPlay : null),
      VrxRow(label: 'Length', value: mmss(take.seconds)),
      if (take.bytes > 0) VrxRow(label: 'Size', value: sizeText(take.bytes)),
      if (take.format.isNotEmpty) VrxRow(label: 'Format', value: take.format),
      VrxRow(glyph: VrxSymbols.delete, label: 'Delete', onTap: onDelete),
    ]);
  }
}

Future<List<Recording>> listRecordings({int limit = 200}) async {
  final dir = Directory(recordingsDir);
  if (!await dir.exists()) return const [];
  // MEM-10 (review 2026-10-17): the newest `limit` are read, oldest
  // left on disk unread — the list opened EVERY file with no bound, and
  // a full card wedged the recorder's list on I/O
  final names = <String>[];
  await for (final f in dir.list()) {
    if (f is! File || !f.path.endsWith('.wav')) continue;
    names.add(f.path);
  }
  names.sort((a, b) => b.compareTo(a));
  final out = <Recording>[];
  for (final path in names.take(limit)) {
    final f = File(path);
    final raf = await f.open();
    final head = await raf.read(44);
    await raf.close();
    final size = await f.length();
    out.add(Recording(name: f.uri.pathSegments.last, seconds: wavSeconds(head, size), bytes: size, format: wavFormat(head)));
  }
  // newest first: the names carry the time
  out.sort((a, b) => b.name.compareTo(a.name));
  return out;
}

Future<void> main() async {
  final model = RecorderModel();
  runApplet(RecorderApplet(model), actions: _events.stream);
  try {
    final pcm = File('/proc/asound/pcm');
    _events.add(RecorderListed(
      devices: await pcm.exists() ? SoundDevices.parse(await pcm.readAsString()) : const SoundDevices(playback: false, capture: false),
      recordings: await listRecordings(),
    ));
  } on Object catch (err) {
    _events.add(RecorderError(VrxWords.of(err, context: 'recorder: list')));
  }
}
