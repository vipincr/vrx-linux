import 'package:vrx_kit/vrx_kit.dart';

enum ScriptsAction { init, listed, started, output, ended, closed, failed, moved }

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

  /// Back, one step: the input line, the editor, the name, the script's
  /// screen. False at the list (the applet leaves).
  bool back() {
    if (typing) {
      typing = false;
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
    if (action == ScriptsAction.closed) {
      open = null;
      lines.clear();
    }
    if (action == ScriptsAction.moved) error = null;
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
}

class ScriptsState {
  const ScriptsState();
}
