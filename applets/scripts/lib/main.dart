import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' hide Intent; // vrx's Intent
import 'package:vrx_kit/vrx_kit.dart';

import 'state.dart';

final _events = StreamController<ScriptsAction>();

/// The scripts folder: the applet's state directory, on /data.
String get scriptsDir => '${Platform.environment['HOME'] ?? '/var/lib/vrx/scripts'}/scripts';

/// Scripts: the Python files in [scriptsDir], run with python3 as the
/// applet's own user, their output in a console.
class ScriptsApplet extends Applet<ScriptsState, ScriptsAction, ScriptsView> {
  ScriptsApplet(this.model);

  final ScriptsModel model;
  Process? _process;

  @override
  ScriptsState get initial => model.initial;

  @override
  ScriptsAction get bootAction => model.bootAction;

  @override
  ScriptsView reduce(ScriptsState state, ScriptsAction action) => model.reduce(state, action);

  @override
  ScriptsState get snapshot => model.snapshot;

  Future<void> run(String script) async {
    model.start(script);
    _events.add(ScriptsAction.started);
    try {
      final p = await Process.start('python3', ['-u', '$scriptsDir/$script'], workingDirectory: scriptsDir);
      _process = p;
      void pipe(Stream<List<int>> s) => s.transform(const Utf8Decoder(allowMalformed: true)).listen((text) {
            model.add(text);
            _events.add(ScriptsAction.output);
          });
      pipe(p.stdout);
      pipe(p.stderr);
      final code = await p.exitCode;
      model
        ..running = false
        ..exit = code;
    } on Object catch (err) {
      model
        ..running = false
        ..error = VrxWords.of(err, context: 'scripts: python3');
    }
    _process = null;
    _events.add(ScriptsAction.ended);
  }

  void stop() => _process?.kill(ProcessSignal.sigterm);

  void _close() {
    stop();
    _events.add(ScriptsAction.closed);
  }

  @override
  Widget build(BuildContext context, ScriptsView view) {
    final open = view.open;
    return Scaffold(
      body: SafeArea(
        child: open == null ? _List(view: view, onRun: (s) => unawaited(run(s))) : _Console(view: view, onBack: _close, onStop: stop, onAgain: () => unawaited(run(open))),
      ),
    );
  }
}

class _List extends StatelessWidget {
  const _List({required this.view, required this.onRun});

  final ScriptsView view;
  final void Function(String) onRun;

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      const VrxHeader(title: 'Scripts', onBack: Nav.pop),
      Expanded(
        child: view.scripts.isEmpty
            ? Padding(
                padding: EdgeInsets.all(ScaledSpacing.of(context).md),
                child: Text('No scripts. Put .py files in $scriptsDir.', style: TypeRole.body(context)),
              )
            : ListView.builder(
                itemCount: view.scripts.length,
                itemBuilder: (context, i) => VrxRow(
                  glyph: VrxSymbols.play_arrow,
                  label: view.scripts[i],
                  onTap: () => onRun(view.scripts[i]),
                ),
              ),
      ),
      if (view.error != null) VrxBanner(text: view.error),
    ]);
  }
}

class _Console extends StatelessWidget {
  const _Console({required this.view, required this.onBack, required this.onStop, required this.onAgain});

  final ScriptsView view;
  final VoidCallback onBack, onStop, onAgain;

  @override
  Widget build(BuildContext context) {
    final space = ScaledSpacing.of(context);
    final mono = TypeRole.caption(context).copyWith(fontFamily: 'Liberation Mono');
    final status = view.error ?? (view.running ? 'Running…' : 'Ended (exit ${view.exit})');
    return Column(children: [
      VrxHeader(title: view.open ?? '', onBack: onBack),
      Expanded(
        child: ColoredBox(
          // the output rests on the surface, a card on the page
          color: VrxTheme.of(context).surface,
          // the newest line at the bottom, where the eye is
          child: ListView.builder(
            reverse: true,
            padding: EdgeInsets.all(space.sm),
            itemCount: view.lines.length,
            itemBuilder: (context, i) => Text(view.lines[view.lines.length - 1 - i], style: mono),
          ),
        ),
      ),
      VrxRow(label: status, value: view.running ? 'Stop' : 'Run again', onTap: view.running ? onStop : onAgain),
    ]);
  }
}

/// Copy the bundled samples into the scripts folder the first time.
Future<void> seedSamples(Directory samples) async {
  final dir = Directory(scriptsDir);
  if (await dir.exists()) return;
  await dir.create(recursive: true);
  if (!await samples.exists()) return;
  await for (final f in samples.list()) {
    if (f is File && f.path.endsWith('.py')) await f.copy('${dir.path}/${f.uri.pathSegments.last}');
  }
}

Future<List<String>> listScripts() async {
  final dir = Directory(scriptsDir);
  if (!await dir.exists()) return const [];
  final names = <String>[
    await for (final f in dir.list())
      if (f is File && f.path.endsWith('.py')) f.uri.pathSegments.last,
  ]..sort();
  return names;
}

Future<void> main() async {
  final model = ScriptsModel();
  runApplet(ScriptsApplet(model), actions: _events.stream);
  try {
    // the recipe installs the samples beside the bundle's manifest
    await seedSamples(Directory('/system/defaults/scripts/samples'));
    model.scripts = await listScripts();
  } on Object catch (err) {
    model.error = VrxWords.of(err, context: 'scripts: list');
  }
  _events.add(ScriptsAction.listed);
}
