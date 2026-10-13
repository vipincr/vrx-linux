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
    _move(() => model
      ..selected = name
      ..naming = false
      ..editing = true);
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
    model.start(script);
    _events.add(ScriptsAction.started);
    try {
      final args = script == replName ? ['-u', '-i', '-q'] : ['-u', '$scriptsDir/$script'];
      final p = await Process.start('python3', args, workingDirectory: scriptsDir);
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

  /// A line to the running script's input, echoed in the console.
  void send(String line) {
    final p = _process;
    model.typing = false;
    if (p != null) {
      p.stdin.writeln(line);
      model.add('> $line\n');
    }
    _events.add(ScriptsAction.output);
  }

  void _move(void Function() change) {
    change();
    _events.add(ScriptsAction.moved);
  }

  void _back() {
    if (!model.back()) {
      unawaited(Nav.pop());
      return;
    }
    _events.add(ScriptsAction.moved);
  }

  Future<void> save(String name, String text) async {
    try {
      await VrxFile.writeAtomic('$scriptsDir/$name', text);
      model
        ..editing = false
        ..scripts = await listScripts();
    } on Object catch (err) {
      model.error = VrxWords.of(err, context: 'scripts: save');
    }
    _events.add(ScriptsAction.moved);
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
    } else if (open != null) {
      body = _Console(
        view: view,
        onBack: _close,
        onStop: stop,
        onAgain: () => unawaited(run(open)),
        onType: () => _move(() => model.typing = true),
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
    } else if (selected != null) {
      body = VrxList(children: [
        VrxHeader(title: selected, onBack: _back),
        VrxRow(glyph: VrxSymbols.play_arrow, label: 'Run', onTap: () => unawaited(run(selected))),
        VrxRow(glyph: VrxSymbols.edit, label: 'Edit', onTap: () => unawaited(edit(selected))),
      ]);
    } else {
      body = _List(
        view: view,
        onOpen: (s) => _move(() => model.selected = s),
        onRepl: () => unawaited(run(replName)),
        onNew: () => _move(() => model.naming = true),
        onBack: _back,
      );
    }
    return Scaffold(body: SafeArea(child: body));
  }
}

class _List extends StatelessWidget {
  const _List({required this.view, required this.onOpen, required this.onRepl, required this.onNew, required this.onBack});

  final ScriptsView view;
  final void Function(String) onOpen;
  final VoidCallback onRepl, onNew, onBack;

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      VrxHeader(title: 'Scripts', onBack: onBack),
      VrxRow(glyph: VrxSymbols.terminal, label: replName, onTap: onRepl),
      VrxRow(glyph: VrxSymbols.add, label: 'New script', onTap: onNew),
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
  const _Console({required this.view, required this.onBack, required this.onStop, required this.onAgain, required this.onType});

  final ScriptsView view;
  final VoidCallback onBack, onStop, onAgain, onType;

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
      VrxRow(label: status, value: view.running ? 'Stop' : 'Run again', onTap: view.running ? onStop : onAgain),
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
    final field = Padding(
      padding: EdgeInsets.symmetric(horizontal: space.sm),
      child: TextField(
        controller: _text,
        maxLines: null,
        expands: true,
        style: mono,
        keyboardType: TextInputType.multiline,
        decoration: const InputDecoration(border: InputBorder.none, isDense: true),
        // as the kit's entry: no drag handles over the text (they sit on
        // the lines under a finger); the arrows move the cursor
        enableInteractiveSelection: false,
        // a tap in the text brings the keyboard up where it is shown on demand
        onTap: () {
          if (!_keys) setState(() => _keys = true);
        },
      ),
    );
    return LayoutBuilder(builder: (context, box) {
      // a header, a few lines and the keyboard; on a panel too short for
      // them, the strip steps aside, the header is one row, and the
      // keyboard is the terminal's (shorter, with its own Hide and Back)
      // shown on a tap in the text
      final roomy = box.maxHeight >= VrxKeyboard.heightOf(context) + 4 * space.touch;
      if (roomy) {
        return Column(children: [
          VrxHeader(title: widget.name, onBack: widget.onBack, action: save),
          Expanded(child: field),
          VrxKeyboard(controller: _text, onDone: _newLine),
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
                  VrxIconButton(glyph: VrxSymbols.arrow_back, onTap: widget.onBack),
                  SizedBox(width: space.xs),
                  Expanded(child: VrxFitText(widget.name, style: TypeRole.of(context, VrxTypeRole.list), maxLines: 1)),
                  save,
                  SizedBox(width: space.inset),
                ]),
              ),
              Divider(height: space.xs, thickness: Strokes.hairline, color: VrxTheme.of(context).outlineFaint),
            ],
            Expanded(child: field),
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
  try {
    // the recipe installs the samples beside the bundle's manifest
    await seedSamples(Directory('/system/defaults/scripts/samples'));
    model.scripts = await listScripts();
  } on Object catch (err) {
    model.error = VrxWords.of(err, context: 'scripts: list');
  }
  _events.add(ScriptsAction.listed);
}
