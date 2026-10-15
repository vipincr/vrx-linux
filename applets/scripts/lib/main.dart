import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' hide Intent; // vrx's Intent
import 'package:vrx_kit/vrx_kit.dart';

import 'state.dart';

final _events = StreamController<ScriptsAction>();

/// The scripts folder: the applet's state directory, on /data.
String get scriptsDir => '${Platform.environment['HOME'] ?? '/var/lib/vrx/scripts'}/scripts';

/// Where the recipe installs the applet's files: the samples and the
/// `vrx` Python module a script draws its screen with (plan 0013 D13).
const bundleDir = '/system/defaults/scripts';

/// Scripts: the Python files in [scriptsDir], run with python3 as the
/// applet's own user, their output in a console that also takes input
/// lines; Python's own prompt (`python3 -i`); an editor that saves a
/// script whole (VrxFile.writeAtomic).
class ScriptsApplet extends Applet<ScriptsState, ScriptsAction, ScriptsView> {
  ScriptsApplet(this.model);

  final ScriptsModel model;
  Process? _process;

  /// The text the editor opened with, read once when it opened.
  String _editing = '';

  Future<void> edit(String name) async {
    _editing = await _read(name);
    _events.add(ScriptsEdit(name));
  }

  @override
  ScriptsState get initial => model.initial;

  @override
  ScriptsAction get bootAction => model.bootAction;

  @override
  ScriptsView reduce(ScriptsState state, ScriptsAction action) => model.reduce(state, action);

  @override
  ScriptsState get snapshot => model.snapshot;

  /// Run [script], or Python's prompt when it is [replName].
  Future<void> run(String script) async {
    if (_process != null) return;
    _events.add(ScriptsStarted(script));
    try {
      final args = script == replName ? ['-u', '-i', '-q'] : ['-u', '$scriptsDir/$script'];
      final p = await Process.start('python3', args,
          workingDirectory: scriptsDir, environment: {'PYTHONPATH': '$bundleDir/python'});
      _process = p;
      // a whole line at a time: a line that is a screen (the vrx module's
      // JSON) draws it; any other line is output for the console
      p.stdout.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()).listen((line) {
        final drawn = ScriptScreen.parse(line);
        _events.add(drawn != null ? ScriptsScreen(drawn.screen) : ScriptsOutput('$line\n'));
      });
      p.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen((line) => _events.add(ScriptsOutput('$line\n')));
      final code = await p.exitCode;
      _process = null;
      _events.add(ScriptsEnded(exit: code));
    } on Object catch (err) {
      _process = null;
      _events.add(ScriptsEnded(error: VrxWords.of(err, context: 'scripts: python3')));
    }
  }

  void stop() => _process?.kill(ProcessSignal.sigterm);

  /// A line to the running script's input, echoed in the console.
  void send(String line) {
    final p = _process;
    p?.stdin.writeln(line);
    _events.add(ScriptsSent(line, echoed: p != null));
  }

  /// A row of the script's screen was pressed: its id to the script.
  void tap(String id) => _process?.stdin.writeln(tapLine(id));

  Future<void> startBackground(String script) async {
    try {
      await VrxSystem.scripts.start(script);
    } on Object catch (err) {
      _events.add(ScriptsBackground(error: VrxWords.of(err, context: 'scripts: background')));
    }
  }

  Future<void> stopBackground(String script) async {
    try {
      await VrxSystem.scripts.stop(script);
    } on Object catch (err) {
      _events.add(ScriptsBackground(error: VrxWords.of(err, context: 'scripts: background')));
    }
  }

  void _back() {
    if (model.atRoot) {
      unawaited(Nav.pop());
      return;
    }
    _events.add(ScriptsAction.back);
  }

  Future<void> save(String name, String text) async {
    try {
      await VrxFile.writeAtomic('$scriptsDir/$name', text);
      _events.add(ScriptsSaved(scripts: await listScripts()));
    } on Object catch (err) {
      _events.add(ScriptsSaved(error: VrxWords.of(err, context: 'scripts: save')));
    }
  }

  Future<String> _read(String name) async {
    try {
      return await File('$scriptsDir/$name').readAsString();
    } on FileSystemException {
      return '';
    }
  }

  void _close() {
    stop();
    _events.add(ScriptsAction.closed);
  }

  @override
  Widget build(BuildContext context, ScriptsView view) {
    final open = view.open;
    final selected = view.selected;
    final Widget body;
    if (open != null && view.typing) {
      body = VrxTextEntry(title: 'A line for $open', hint: 'input', onBack: _back, onDone: send);
    } else if (open != null && view.screen != null && !view.output) {
      body = _ScriptScreenView(
        view: view,
        onBack: _close,
        onTap: tap,
        onStop: stop,
        onAgain: () => unawaited(run(open)),
        onOutput: () => _events.add(ScriptsAction.output),
      );
    } else if (open != null) {
      body = _Console(
        view: view,
        onBack: _close,
        onStop: stop,
        onAgain: () => unawaited(run(open)),
        onType: () => _events.add(ScriptsAction.typing),
        onScreen: view.screen == null ? null : () => _events.add(ScriptsAction.output),
      );
    } else if (view.naming) {
      body = VrxTextEntry(
        title: 'New script',
        hint: 'name.py',
        helper: (t) => ScriptsModel.fileNameFor(t).isEmpty ? 'Letters, digits, - and _' : 'Saved as ${ScriptsModel.fileNameFor(t)}',
        onBack: _back,
        onDone: (t) {
          final name = ScriptsModel.fileNameFor(t);
          if (name.isEmpty) return;
          unawaited(edit(name));
        },
      );
    } else if (selected != null && view.editing) {
      body = _Editor(
        key: ValueKey(selected),
        name: selected,
        initial: _editing,
        onBack: _back,
        onSave: (t) => unawaited(save(selected, t)),
      );
    } else if (view.showRunning) {
      body = _Running(view: view, onBack: _back, onStop: (s) => unawaited(stopBackground(s)));
    } else if (selected != null) {
      final inBackground = view.background.any((u) => u.script == selected);
      body = VrxList(children: [
        VrxHeader(title: selected, onBack: _back),
        VrxRow(glyph: VrxSymbols.play_arrow, label: 'Run', onTap: () => unawaited(run(selected))),
        // a background script is systemd's (vrx-script@<name>): only a name
        // that can be its instance runs there
        if (ScriptUnit.instanceFor(selected) != null)
          inBackground
              ? VrxRow(label: 'In the background', value: 'Stop', onTap: () => unawaited(stopBackground(selected)))
              : VrxRow(label: 'Run in the background', onTap: () => unawaited(startBackground(selected))),
        VrxRow(glyph: VrxSymbols.edit, label: 'Edit', onTap: () => unawaited(edit(selected))),
        if (view.error != null) VrxBanner(text: view.error),
      ]);
    } else {
      body = _List(
        view: view,
        onOpen: (s) => _events.add(ScriptsSelect(s)),
        onRepl: () => unawaited(run(replName)),
        onNew: () => _events.add(ScriptsAction.naming),
        onRunning: () => _events.add(ScriptsAction.running),
        onBack: _back,
      );
    }
    return Scaffold(body: SafeArea(child: body));
  }
}

class _List extends StatelessWidget {
  const _List(
      {required this.view, required this.onOpen, required this.onRepl, required this.onNew, required this.onRunning, required this.onBack});

  final ScriptsView view;
  final void Function(String) onOpen;
  final VoidCallback onRepl, onNew, onRunning, onBack;

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      VrxHeader(title: 'Scripts', onBack: onBack),
      VrxRow(glyph: VrxSymbols.terminal, label: replName, onTap: onRepl),
      VrxRow(glyph: VrxSymbols.add, label: 'New script', onTap: onNew),
      VrxRow(
        label: 'In the background',
        value: view.background.isEmpty ? 'None' : '${view.background.length}',
        widestValue: '99',
        onTap: onRunning,
      ),
      Expanded(
        child: view.scripts.isEmpty
            ? Padding(
                padding: EdgeInsets.all(ScaledSpacing.of(context).md),
                child: Text('No scripts. Put .py files in $scriptsDir.', style: TypeRole.body(context)),
              )
            : ListView.builder(
                itemCount: view.scripts.length,
                itemBuilder: (context, i) => VrxRow(
                  glyph: VrxSymbols.description,
                  label: view.scripts[i],
                  onTap: () => onOpen(view.scripts[i]),
                ),
              ),
      ),
      if (view.error != null) VrxBanner(text: view.error),
    ]);
  }
}

class _Console extends StatelessWidget {
  const _Console(
      {required this.view, required this.onBack, required this.onStop, required this.onAgain, required this.onType, this.onScreen});

  final ScriptsView view;
  final VoidCallback onBack, onStop, onAgain, onType;

  /// Back to the script's own screen, when it drew one.
  final VoidCallback? onScreen;

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
      // a running script reads its input from here
      if (view.running) VrxRow(glyph: VrxSymbols.keyboard, label: 'Type a line', onTap: onType),
      if (onScreen != null) VrxRow(label: 'Its screen', onTap: onScreen),
      VrxRow(label: status, value: view.running ? 'Stop' : 'Run again', onTap: view.running ? onStop : onAgain),
    ]);
  }
}

/// The screen a running script drew (the vrx module): its rows, each
/// sending its id to the script when pressed, its paragraphs, then the
/// run's state and the way to its printed output.
class _ScriptScreenView extends StatelessWidget {
  const _ScriptScreenView(
      {required this.view, required this.onBack, required this.onTap, required this.onStop, required this.onAgain, required this.onOutput});

  final ScriptsView view;
  final VoidCallback onBack, onStop, onAgain, onOutput;
  final void Function(String id) onTap;

  @override
  Widget build(BuildContext context) {
    final screen = view.screen!;
    final space = ScaledSpacing.of(context);
    final status = view.error ?? (view.running ? 'Running…' : 'Ended (exit ${view.exit})');
    return Column(children: [
      VrxHeader(title: screen.title.isEmpty ? (view.open ?? '') : screen.title, onBack: onBack),
      Expanded(
        child: ListView(children: [
          for (final item in screen.items)
            if (item.text != null)
              Padding(
                padding: EdgeInsets.symmetric(horizontal: space.inset, vertical: space.sm),
                child: Text(item.text!, style: TypeRole.body(context)),
              )
            else
              VrxRow(
                label: item.label,
                value: item.value,
                onTap: item.tap == null || !view.running ? null : () => onTap(item.tap!),
              ),
        ]),
      ),
      VrxRow(label: 'Its output', onTap: onOutput),
      VrxRow(label: status, value: view.running ? 'Stop' : 'Run again', onTap: view.running ? onStop : onAgain),
    ]);
  }
}

/// What runs in the background (systemd's vrx-script@ units): a tap
/// stops one, or clears one systemd stopped after it kept failing.
class _Running extends StatelessWidget {
  const _Running({required this.view, required this.onBack, required this.onStop});

  final ScriptsView view;
  final VoidCallback onBack;
  final void Function(String script) onStop;

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      VrxHeader(title: 'In the background', onBack: onBack),
      Expanded(
        child: view.background.isEmpty
            ? Padding(
                padding: EdgeInsets.all(ScaledSpacing.of(context).md),
                child: Text('Nothing runs in the background. Open a script and choose Run in the background.',
                    style: TypeRole.body(context)),
              )
            : ListView(children: [
                for (final u in view.background)
                  VrxRow(
                    glyph: u.state == ScriptUnitState.running ? null : VrxSymbols.warning,
                    label: u.script,
                    detail: unitWords(u),
                    value: u.state == ScriptUnitState.failed ? 'Clear' : 'Stop',
                    onTap: () => onStop(u.script),
                  ),
              ]),
      ),
      if (view.error != null) VrxBanner(text: view.error),
    ]);
  }
}

/// A script's text, edited whole: a monospace field over the kit's
/// keyboard (its done key starts a new line), saved with Save.
class _Editor extends StatefulWidget {
  const _Editor({super.key, required this.name, required this.initial, required this.onBack, required this.onSave});

  final String name;
  final String initial;
  final VoidCallback onBack;
  final void Function(String text) onSave;

  @override
  State<_Editor> createState() => _EditorState();
}

class _EditorState extends State<_Editor> {
  late final _text = TextEditingController(text: widget.initial);

  /// On a short panel the keyboard is shown on demand.
  bool _keys = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  /// Put [s] at the cursor, over any selection.
  void _insert(String s) {
    final sel = _text.selection;
    final at = sel.isValid ? sel.start : _text.text.length;
    final end = sel.isValid ? sel.end : at;
    _text.value = TextEditingValue(
      text: _text.text.replaceRange(at, end, s),
      selection: TextSelection.collapsed(offset: at + s.length),
    );
  }

  void _newLine() => _insert('\n');

  // the terminal keyboard's keys, as an editor reads them
  void _key(VrxTermKey key) {
    final t = _text.text;
    final sel = _text.selection;
    final at = sel.isValid ? sel.start : t.length;
    switch (key) {
      case VrxTermKey.enter:
        _newLine();
      case VrxTermKey.tab:
        _insert('    ');
      case VrxTermKey.backspace:
        if (sel.isValid && !sel.isCollapsed) {
          _insert('');
        } else if (at > 0) {
          _text.value = TextEditingValue(text: t.replaceRange(at - 1, at, ''), selection: TextSelection.collapsed(offset: at - 1));
        }
      case VrxTermKey.left:
        _text.selection = TextSelection.collapsed(offset: (at - 1).clamp(0, t.length));
      case VrxTermKey.right:
        _text.selection = TextSelection.collapsed(offset: (at + 1).clamp(0, t.length));
      case VrxTermKey.up || VrxTermKey.down:
        // a line up or down, at the same column where it can be
        final lineStart = t.lastIndexOf('\n', at - 1) + 1;
        final col = at - lineStart;
        if (key == VrxTermKey.up) {
          if (lineStart == 0) break;
          final prevStart = t.lastIndexOf('\n', lineStart - 2) + 1;
          _text.selection = TextSelection.collapsed(offset: (prevStart + col).clamp(prevStart, lineStart - 1));
        } else {
          final next = t.indexOf('\n', at);
          if (next < 0) break;
          final nextEnd = t.indexOf('\n', next + 1);
          _text.selection = TextSelection.collapsed(offset: (next + 1 + col).clamp(next + 1, nextEnd < 0 ? t.length : nextEnd));
        }
      case VrxTermKey.escape:
        setState(() => _keys = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final space = ScaledSpacing.of(context);
    final mono = TypeRole.caption(context).copyWith(fontFamily: 'Liberation Mono');
    final save = VrxChip(label: 'Save', filled: true, onTap: () => widget.onSave(_text.text));
    // roomy: the kit's keyboard comes up for the field (plan 0013 D6);
    // short: the field takes no keyboard from the kit and the terminal's
    // keys (with arrows, Hide and Back) come up on a tap in the text
    Widget field({required bool roomy}) => Padding(
      padding: EdgeInsets.symmetric(horizontal: space.sm),
      // the text area says what it holds, even empty (plan 0014 D8)
      child: MergeSemantics(
          child: Semantics(
        label: 'The script ${widget.name}',
        child: VrxTextField(
        controller: _text,
        maxLines: null,
        expands: true,
        style: mono,
        keyboardType: roomy ? TextInputType.multiline : TextInputType.none,
        decoration: const InputDecoration(border: InputBorder.none, isDense: true),
        // a tap in the text brings the terminal's keys up where they are
        // shown on demand
        onTap: () {
          if (!roomy && !_keys) setState(() => _keys = true);
        },
      ),
      )),
    );
    return LayoutBuilder(builder: (context, _) {
      // a header, a few lines and the keyboard; on a panel too short for
      // them, the strip steps aside, the header is one row, and the
      // keyboard is the terminal's (shorter, with its own Hide and Back)
      // shown on a tap in the text
      // decided on the display, never on this box: the kit's keyboard
      // takes its share of the box when it comes up, and the decision must
      // not change because it did
      final view = View.of(context);
      final screen = view.physicalSize.height / view.devicePixelRatio - VrxStatusStrip.heightOf(context);
      final roomy = screen >= VrxKeyboard.heightOf(context) + 4 * space.touch;
      if (roomy) {
        return Column(children: [
          VrxHeader(title: widget.name, onBack: widget.onBack, action: save),
          Expanded(child: field(roomy: true)),
        ]);
      }
      return VrxNoChrome(
        child: VrxBackOffer(
          onBack: _keys ? () => setState(() => _keys = false) : widget.onBack,
          child: Column(children: [
            if (!_keys) ...[
              SizedBox(
                height: space.touch,
                child: Row(children: [
                  VrxIconButton(glyph: VrxSymbols.arrow_back, label: 'Back', onTap: widget.onBack),
                  SizedBox(width: space.xs),
                  Expanded(child: VrxFitText(widget.name, style: TypeRole.of(context, VrxTypeRole.list), maxLines: 1)),
                  save,
                  SizedBox(width: space.inset),
                ]),
              ),
              Divider(height: space.xs, thickness: Strokes.hairline, color: VrxTheme.of(context).outlineFaint),
            ],
            Expanded(child: field(roomy: false)),
            if (_keys)
              VrxKeyboard.terminal(
                onText: (t, {ctrl = false}) => _insert(t),
                onKey: _key,
                onHide: () => setState(() => _keys = false),
                onBack: () => setState(() => _keys = false),
              ),
          ]),
        ),
      );
    });
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
  // what runs in the background, from systemd's unit and job signals
  VrxSystem.scripts.watch().listen(
        (units) => _events.add(ScriptsBackground(units: units)),
        onError: (Object err) => _events.add(ScriptsBackground(error: VrxWords.of(err, context: 'scripts: background'))),
      );
  try {
    // the recipe installs the samples beside the bundle's manifest
    await seedSamples(Directory('$bundleDir/samples'));
    _events.add(ScriptsListed(scripts: await listScripts()));
  } on Object catch (err) {
    _events.add(ScriptsListed(error: VrxWords.of(err, context: 'scripts: list')));
  }
}
