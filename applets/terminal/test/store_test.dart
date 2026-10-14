import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';
import 'package:xterm/xterm.dart';

import 'package:terminal_applet/state.dart';

void main() {
  test('the keyboard toggles; a session starts and ends', () {
    final harness = StoreHarness(TerminalModel());
    harness.assertView((v) => v.keyboard && !v.running, because: 'the keyboard is up before any shell');
    harness.dispatch(TerminalAction.started);
    harness.dispatch(TerminalAction.keyboardToggled);
    harness.assertView((v) => !v.keyboard && v.running);
    harness.dispatch(TerminalAction.ended);
    harness.assertView((v) => !v.running);
    harness.verify(fresh: TerminalModel.new, probes: TerminalAction.values);
  });

  test('keys reach the program as the terminal encodes them', () {
    final sent = <String>[];
    final terminal = Terminal(onOutput: sent.add);
    typeInto(terminal, 'c', ctrl: true);
    typeInto(terminal, 'ls');
    terminal.keyInput(terminalKeyFor(VrxTermKey.up));
    terminal.keyInput(terminalKeyFor(VrxTermKey.enter));
    expect(sent, ['\x03', 'ls', '\x1b[A', '\r']);
  });
}
