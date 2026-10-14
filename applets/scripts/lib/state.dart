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
}

/// [closed]: the console closed; [typing]: the input line opened;
/// [naming]: a new script's name is being typed.
enum ScriptsSignal implements ScriptsAction { init, closed, back, typing, naming }

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
  });

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
      lines.clear();
    } else if (editing) {
      editing = false;
    } else if (naming) {
      naming = false;
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
      case ScriptsSignal.closed:
        open = null;
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
  bool get atRoot => !typing && open == null && !editing && !naming && selected == null;

  @override
  Object? get fingerprint => [scripts, open, running, lines.toList(), exit, error, selected, editing, naming, typing];
}

class ScriptsState {
  const ScriptsState();
}
