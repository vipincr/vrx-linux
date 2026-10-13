import 'package:vrx_kit/vrx_kit.dart';
import 'package:xterm/xterm.dart';

enum TerminalAction { init, keyboardToggled, started, ended }

class TermView {
  const TermView({required this.keyboard, required this.running});

  /// The on-screen keyboard is up; hidden, the output has the screen.
  final bool keyboard;

  /// A shell is attached; when it ends, a tap starts another.
  final bool running;
}

class TerminalModel extends StoreModel<TerminalState, TerminalAction, TermView> {
  bool keyboard = true;
  bool running = false;

  @override
  TerminalState get initial => const TerminalState();

  @override
  TerminalAction get bootAction => TerminalAction.init;

  @override
  TermView reduce(TerminalState state, TerminalAction action) {
    switch (action) {
      case TerminalAction.keyboardToggled:
        keyboard = !keyboard;
      case TerminalAction.started:
        running = true;
      case TerminalAction.ended:
        running = false;
      case TerminalAction.init:
        break;
    }
    return TermView(keyboard: keyboard, running: running);
  }

  @override
  TerminalState get snapshot => const TerminalState();
}

class TerminalState {
  const TerminalState();
}

/// The xterm key a keyboard key sends: the terminal encodes it for the
/// mode the program asked for (an arrow is ESC [ A, or ESC O A in
/// application cursor mode).
TerminalKey terminalKeyFor(VrxTermKey key) => switch (key) {
      VrxTermKey.escape => TerminalKey.escape,
      VrxTermKey.tab => TerminalKey.tab,
      VrxTermKey.backspace => TerminalKey.backspace,
      VrxTermKey.enter => TerminalKey.enter,
      VrxTermKey.left => TerminalKey.arrowLeft,
      VrxTermKey.up => TerminalKey.arrowUp,
      VrxTermKey.down => TerminalKey.arrowDown,
      VrxTermKey.right => TerminalKey.arrowRight,
    };

/// Send typed text: with Ctrl, a letter becomes its control character
/// (Ctrl-C is 0x03, the interrupt the pty turns into SIGINT).
void typeInto(Terminal terminal, String text, {bool ctrl = false}) {
  if (ctrl && text.length == 1 && terminal.charInput(text.toLowerCase().codeUnitAt(0), ctrl: true)) return;
  terminal.textInput(text);
}
