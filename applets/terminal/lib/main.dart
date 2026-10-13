import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' hide Intent; // vrx's Intent
import 'package:vrx_kit/vrx_kit.dart';
import 'package:xterm/xterm.dart' hide TerminalView, TerminalState;
import 'package:xterm/xterm.dart' as xterm show TerminalView;

import 'pty.dart';
import 'state.dart';

final _events = StreamController<TerminalAction>();

/// Terminal: zsh on a pseudo-terminal, debug images only. The unit's
/// debug drop-in lifts the applet sandbox and sudoers lets vrx-terminal
/// become root, so this is the bench's shell on the device itself.
class TerminalApplet extends Applet<TerminalState, TerminalAction, TermView> {
  TerminalApplet(this.model);

  final TerminalModel model;
  final terminal = Terminal(maxLines: 2000);
  Pty? _pty;

  @override
  TerminalState get initial => model.initial;

  @override
  TerminalAction get bootAction => model.bootAction;

  @override
  TermView reduce(TerminalState state, TerminalAction action) => model.reduce(state, action);

  @override
  TerminalState get snapshot => model.snapshot;

  /// Start a shell sized to the terminal's current grid.
  Future<void> start() async {
    try {
      final pty = await Pty.start(
        columns: terminal.viewWidth,
        rows: terminal.viewHeight,
        environment: {'SHELL': '/bin/zsh'},
        workingDirectory: Platform.environment['HOME'],
      );
      _pty = pty;
      _events.add(TerminalAction.started);
      pty.output.cast<List<int>>().transform(const Utf8Decoder(allowMalformed: true)).listen(
            terminal.write,
            onDone: () {
              _pty = null;
              terminal.write('\r\n[session ended: tap to start another]\r\n');
              _events.add(TerminalAction.ended);
            },
          );
    } on Object catch (err) {
      terminal.write('cannot start the shell: $err\r\n');
    }
  }

  void wire() {
    terminal.onOutput = (data) => _pty?.write(utf8.encode(data));
    terminal.onResize = (columns, rows, _, __) => _pty?.resize(columns, rows);
  }

  @override
  Widget build(BuildContext context, TermView view) {
    final scale = VrxScale.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: xterm.TerminalView(
              terminal,
              // 2mm text: about 35 columns on a 43mm panel, where body
              // text (3.5mm) would give 20 (AGENTS.md rule 10)
              textStyle: TerminalStyle(fontSize: Spacing.sm * scale, fontFamily: 'Liberation Mono'),
              padding: EdgeInsets.all(Spacing.xs * scale),
              autofocus: true,
              hardwareKeyboardOnly: true,
              onTapUp: (_, __) {
                if (view.running) {
                  AppletScope.dispatch(context, TerminalAction.keyboardToggled);
                } else {
                  unawaited(start());
                }
              },
            ),
          ),
          if (view.keyboard)
            VrxKeyboard.terminal(
              onText: (text, {ctrl = false}) => typeInto(terminal, text, ctrl: ctrl),
              onKey: (key) => terminal.keyInput(terminalKeyFor(key)),
              onHide: () => AppletScope.dispatch(context, TerminalAction.keyboardToggled),
              onBack: Nav.pop,
            ),
        ]),
      ),
    );
  }
}

Future<void> main() async {
  final applet = TerminalApplet(TerminalModel())..wire();
  runApplet(applet, actions: _events.stream);
  await applet.start();
}
