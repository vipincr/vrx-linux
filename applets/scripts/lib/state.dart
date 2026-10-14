import 'dart:convert';

import 'package:vrx_kit/vrx_kit.dart';

/// Everything Scripts reacts to (plan 0013 D1: the reducer is the only
/// writer): a signal, or what happened, as data.
sealed class ScriptsAction {
  const ScriptsAction();

  static const init = ScriptsSignal.init;
  static const closed = ScriptsSignal.closed;
  static const back = ScriptsSignal.back;
  static const typing = ScriptsSignal.typing;
  static const naming = ScriptsSignal.naming;
  static const running = ScriptsSignal.running;
  static const output = ScriptsSignal.output;
}

/// [closed]: the console closed; [typing]: the input line opened;
/// [naming]: a new script's name is being typed; [running]: the list of
/// background scripts opened; [output]: between a script's own screen and
/// its printed output.
enum ScriptsSignal implements ScriptsAction { init, closed, back, typing, naming, running, output }

/// The running script drew its own screen, or cleared it (null).
final class ScriptsScreen implements ScriptsAction {
  const ScriptsScreen(this.screen);

  final ScriptScreen? screen;
}

/// What runs in the background, as systemd reports it.
final class ScriptsBackground implements ScriptsAction {
  const ScriptsBackground({this.units, this.error});

  final List<ScriptUnit>? units;
  final String? error;
}

/// The scripts folder was listed, or could not be.
final class ScriptsListed implements ScriptsAction {
  const ScriptsListed({this.scripts, this.error});

  final List<String>? scripts;
  final String? error;
}

/// A script's own screen opened (Run, Edit), or closed (null).
final class ScriptsSelect implements ScriptsAction {
  const ScriptsSelect(this.name);

  final String? name;
}

/// The editor opened on a script.
final class ScriptsEdit implements ScriptsAction {
  const ScriptsEdit(this.name);

  final String name;
}

/// The editor saved (the folder listed again), or could not.
final class ScriptsSaved implements ScriptsAction {
  const ScriptsSaved({this.scripts, this.error});

  final List<String>? scripts;
  final String? error;
}

/// A run started (a script, or the prompt).
final class ScriptsStarted implements ScriptsAction {
  const ScriptsStarted(this.script);

  final String script;
}

/// The running script printed.
final class ScriptsOutput implements ScriptsAction {
  const ScriptsOutput(this.text);

  final String text;
}

/// A line went to the running script's input ([echoed]: it was running).
final class ScriptsSent implements ScriptsAction {
  const ScriptsSent(this.line, {this.echoed = true});

  final String line;
  final bool echoed;
}

/// The run ended: its status, or why Python could not start.
final class ScriptsEnded implements ScriptsAction {
  const ScriptsEnded({this.exit, this.error});

  final int? exit;
  final String? error;
}

/// One item of a script's screen: a row (a label, an optional value, the
/// tap id it sends) or a paragraph ([text]).
class ScriptItem {
  const ScriptItem.row(this.label, {this.value, this.tap}) : text = null;
  const ScriptItem.text(String this.text)
      : label = '',
        value = null,
        tap = null;

  final String label;
  final String? value;
  final String? tap;
  final String? text;

  @override
  bool operator ==(Object other) =>
      other is ScriptItem && other.label == label && other.value == value && other.tap == tap && other.text == text;

  @override
  int get hashCode => Object.hash(label, value, tap, text);
}

/// A screen a script drew with the `vrx` module (plan 0013 D13): one JSON
/// line on its output, `{"screen": [items], "title": "…"}`.
class ScriptScreen {
  const ScriptScreen(this.title, this.items);

  final String title;
  final List<ScriptItem> items;

  /// The most items a screen holds (the module cuts there too).
  static const most = 50;

  /// What [line] means: a screen, a cleared screen (`{"screen": null}`,
  /// returned as an empty title), or null for an ordinary printed line.
  static ({ScriptScreen? screen})? parse(String line) {
    final t = line.trim();
    if (!t.startsWith('{') || !t.contains('"screen"')) return null;
    Object? message;
    try {
      message = jsonDecode(t);
    } on FormatException {
      return null;
    }
    if (message is! Map || !message.containsKey('screen')) return null;
    final raw = message['screen'];
    if (raw == null) return (screen: null);
    if (raw is! List) return null;
    final items = <ScriptItem>[];
    for (final item in raw.take(most)) {
      if (item is! Map) continue;
      if (item['text'] != null) {
        items.add(ScriptItem.text('${item['text']}'));
      } else if (item['row'] != null) {
        items.add(ScriptItem.row('${item['row']}',
            value: item['value']?.toString(), tap: item['tap']?.toString()));
      }
    }
    return (screen: ScriptScreen('${message['title'] ?? ''}', List.unmodifiable(items)));
  }

  @override
  bool operator ==(Object other) =>
      other is ScriptScreen && other.title == title && _sameItems(other.items, items);

  static bool _sameItems(List<ScriptItem> a, List<ScriptItem> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(title, Object.hashAll(items));
}

/// The line a tap on a script's row writes to its input.
String tapLine(String id) => jsonEncode({'tap': id});

/// How a background script is doing, in words.
String unitWords(ScriptUnit u) => switch (u.state) {
      ScriptUnitState.running => 'Running',
      ScriptUnitState.failing => u.restarts == 1 ? 'Failing, restarted once' : 'Failing, restarted ${u.restarts} times',
      ScriptUnitState.failed => 'Stopped after failing',
    };

/// The console's name for the interactive prompt (`python3 -i`).
const replName = 'Python prompt';

/// The console keeps the last lines of a run, enough for a screen and
/// some scrollback, never the whole of a script that prints forever.
const consoleLines = 500;

class ScriptsView {
  const ScriptsView({
    required this.scripts,
    required this.running,
    required this.open,
    required this.lines,
    required this.exit,
    required this.error,
    this.selected,
    this.editing = false,
    this.naming = false,
    this.typing = false,
    this.screen,
    this.output = false,
    this.background = const [],
    this.showRunning = false,
  });

  /// The running script's own screen, or null for its printed output.
  final ScriptScreen? screen;

  /// The printed output is shown over a script that has a screen.
  final bool output;

  /// What runs in the background.
  final List<ScriptUnit> background;

  /// The list of background scripts is open.
  final bool showRunning;

  /// The script whose own screen is up (Run, Edit), or null.
  final String? selected;

  /// The editor is open on [selected].
  final bool editing;

  /// A new script's name is being typed.
  final bool naming;

  /// A line for the running script's input is being typed.
  final bool typing;

  /// Script file names, sorted.
  final List<String> scripts;

  /// The script whose console is open, or null for the list.
  final String? open;

  /// It is still running.
  final bool running;
  final List<String> lines;

  /// Its exit status once ended.
  final int? exit;
  final String? error;
}

class ScriptsModel extends StoreModel<ScriptsState, ScriptsAction, ScriptsView> {
  List<String> scripts = const [];
  String? open;
  bool running = false;
  final lines = <String>[];
  int? exit;
  String? error;
  String? selected;
  bool editing = false;
  bool naming = false;
  bool typing = false;
  ScriptScreen? screen;
  bool output = false;
  List<ScriptUnit> background = const [];
  bool showRunning = false;

  /// A new script's file name from what was typed: `.py` added, nothing
  /// but letters, digits, `-` and `_`; '' when nothing usable is left.
  static String fileNameFor(String typed) {
    var base = typed.trim();
    if (base.endsWith('.py')) base = base.substring(0, base.length - 3);
    base = base.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
    return base.isEmpty ? '' : '$base.py';
  }

  /// Back, one step: the input line, the console, the editor, the name,
  /// the script's screen. False at the list (the applet leaves).
  bool back() {
    if (typing) {
      typing = false;
    } else if (open != null) {
      open = null;
      screen = null;
      output = false;
      lines.clear();
    } else if (editing) {
      editing = false;
    } else if (naming) {
      naming = false;
    } else if (showRunning) {
      showRunning = false;
    } else if (selected != null) {
      selected = null;
    } else {
      return false;
    }
    return true;
  }

  /// Append output, keeping the last [consoleLines].
  void add(String text) {
    lines.addAll(text.split('\n'));
    if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
    if (lines.length > consoleLines) lines.removeRange(0, lines.length - consoleLines);
  }

  void start(String script) {
    open = script;
    screen = null;
    output = false;
    running = true;
    lines.clear();
    exit = null;
    error = null;
  }

  @override
  ScriptsState get initial => const ScriptsState();

  @override
  ScriptsAction get bootAction => ScriptsAction.init;

  @override
  ScriptsView reduce(ScriptsState state, ScriptsAction action) {
    switch (action) {
      case ScriptsListed(scripts: final names, error: final err):
        if (names != null) scripts = names;
        if (err != null) error = err;
      case ScriptsSelect(:final name):
        selected = name;
        error = null;
      case ScriptsEdit(:final name):
        selected = name;
        naming = false;
        editing = true;
        error = null;
      case ScriptsSaved(scripts: final names, error: final err):
        if (err != null) {
          error = err;
        } else {
          editing = false;
          if (names != null) scripts = names;
        }
      case ScriptsStarted(:final script):
        start(script);
      case ScriptsOutput(:final text):
        add(text);
      case ScriptsSent(:final line, :final echoed):
        typing = false;
        if (echoed) add('> $line\n');
      case ScriptsEnded(exit: final code, error: final err):
        running = false;
        if (code != null) exit = code;
        if (err != null) error = err;
      case ScriptsScreen(screen: final drawn):
        screen = drawn;
        if (drawn != null) output = false;
      case ScriptsBackground(units: final units, error: final err):
        if (units != null) background = List.unmodifiable(units);
        if (err != null) error = err;
      case ScriptsSignal.running:
        showRunning = true;
        error = null;
      case ScriptsSignal.output:
        output = !output;
      case ScriptsSignal.closed:
        open = null;
        screen = null;
        output = false;
        lines.clear();
      case ScriptsSignal.back:
        back();
        error = null;
      case ScriptsSignal.typing:
        typing = true;
        error = null;
      case ScriptsSignal.naming:
        naming = true;
        error = null;
      case ScriptsSignal.init:
        break;
    }
    return ScriptsView(
      scripts: scripts,
      open: open,
      running: running,
      lines: List.unmodifiable(lines),
      exit: exit,
      error: error,
      selected: selected,
      editing: editing,
      naming: naming,
      typing: typing,
      screen: screen,
      output: output,
      background: background,
      showRunning: showRunning,
    );
  }

  @override
  ScriptsState get snapshot => const ScriptsState();

  /// The folder is listed again at every start; nothing is kept.
  @override
  void restore(ScriptsState snapshot) {}

  @override
  ScriptsAction get backAction => ScriptsAction.back;

  @override
  bool get atRoot => !typing && open == null && !editing && !naming && !showRunning && selected == null;

  @override
  Object? get fingerprint =>
      [scripts, open, running, lines.toList(), exit, error, selected, editing, naming, typing, screen, output, background.toList(), showRunning];
}

class ScriptsState {
  const ScriptsState();
}
