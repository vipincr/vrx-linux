import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' hide Intent; // vrx's Intent
import 'package:vrx_kit/vrx_kit.dart';

import 'state.dart';

final _events = StreamController<RecorderAction>();

String get recordingsDir => '${Platform.environment['HOME'] ?? '/var/lib/vrx/recorder'}/recordings';

/// Recorder: WAV recordings through ALSA's arecord, played with aplay.
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
    _clock = VrxTicker(const Duration(seconds: 1), () {
      model.elapsed = _watch.elapsedMilliseconds / 1000;
      _events.add(RecorderAction.tick);
    });
  }

  Future<void> _run(List<String> cmd, {required void Function() onEnd}) async {
    try {
      final p = await Process.start(cmd.first, cmd.sublist(1));
      _process = p;
      final err = StringBuffer();
      p.stderr.listen((d) => err.write(String.fromCharCodes(d)));
      unawaited(p.stdout.drain<void>());
      final code = await p.exitCode;
      // a stop is SIGINT: arecord closes the file properly on it
      if (code != 0 && code != -2 && code != 130 && err.isNotEmpty) {
        debugPrint('recorder: ${cmd.first}: ${err.toString().trim()}');
        model.error = VrxWords.failed;
      }
    } on Object catch (e) {
      model.error = VrxWords.of(e, context: 'recorder: ${cmd.first}');
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
    model
      ..recording = true
      ..error = null
      ..elapsed = 0;
    _tick(true);
    _events.add(RecorderAction.recording);
    await _run(['arecord', '-q', '-f', 'S16_LE', '-r', '44100', '-c', '1', '-t', 'wav', '$recordingsDir/$name'], onEnd: () {
      model.recording = false;
      _events.add(RecorderAction.stopped);
    });
    model.recordings = await listRecordings();
    _events.add(RecorderAction.listed);
  }

  Future<void> play(String name) async {
    if (_process != null) return;
    model
      ..playing = name
      ..error = null
      ..elapsed = 0;
    _tick(true);
    _events.add(RecorderAction.playing);
    await _run(['aplay', '-q', '$recordingsDir/$name'], onEnd: () {
      model.playing = null;
      _events.add(RecorderAction.stopped);
    });
  }

  void stop() => _process?.kill(ProcessSignal.sigint);

  Future<void> delete(String name) async {
    try {
      await File('$recordingsDir/$name').delete();
    } on FileSystemException catch (e) {
      model.error = e.message;
    }
    model.recordings = await listRecordings();
    _events.add(RecorderAction.listed);
  }

  @override
  Widget build(BuildContext context, RecorderView view) {
    final busy = view.recording || view.playing != null;
    final d = view.devices;
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
          if (!d.playback) const VrxRow(glyph: VrxSymbols.volume_off, label: 'No sound output on this device'),
          Expanded(
            child: ListView.builder(
              itemCount: view.recordings.length,
              itemBuilder: (context, i) {
                final r = view.recordings[i];
                return VrxRow(
                  glyph: VrxSymbols.play_arrow,
                  label: r.name.replaceAll('.wav', ''),
                  value: mmss(r.seconds),
                  onTap: busy || !d.playback ? null : () => unawaited(play(r.name)),
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

Future<List<Recording>> listRecordings() async {
  final dir = Directory(recordingsDir);
  if (!await dir.exists()) return const [];
  final out = <Recording>[];
  await for (final f in dir.list()) {
    if (f is! File || !f.path.endsWith('.wav')) continue;
    final raf = await f.open();
    final head = await raf.read(44);
    await raf.close();
    out.add(Recording(name: f.uri.pathSegments.last, seconds: wavSeconds(head, await f.length())));
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
    model.devices = await pcm.exists() ? SoundDevices.parse(await pcm.readAsString()) : const SoundDevices(playback: false, capture: false);
    model.recordings = await listRecordings();
  } on Object catch (err) {
    model.error = VrxWords.of(err, context: 'recorder: list');
  }
  _events.add(RecorderAction.listed);
}
