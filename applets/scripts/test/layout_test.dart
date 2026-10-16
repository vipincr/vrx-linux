import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_check/vrx_check.dart';
import 'package:vrx_kit/vrx_kit.dart';

import 'package:scripts_applet/main.dart';
import 'package:scripts_applet/state.dart';

/// The Scripts screens hold on every display vrx drives (vrx_check).
void main() {
  for (final display in allDisplays) {
    testWidgets('scripts list on ${display.name}', (tester) async {
      final model = ScriptsModel()..scripts = ['hello.py', 'system.py', 'a_script_with_a_rather_long_name.py'];
      await expectCleanLayout(tester, ScriptsApplet(model), display: display);
    }, variant: onDevice);
    testWidgets('scripts console on ${display.name}', (tester) async {
      final model = ScriptsModel()
        ..start('system.py')
        ..add('PRETTY_NAME="vrx 0.1.0076"\nRaspberry Pi Compute Module 4 Rev 1.1\nMemTotal:        1887884 kB\nload [\'0.06\', \'0.08\', \'0.03\']\n');
      await expectCleanLayout(tester, ScriptsApplet(model), display: display);
    }, variant: onDevice);
    testWidgets('a script on ${display.name}', (tester) async {
      final model = ScriptsModel()
        ..scripts = ['hello.py']
        ..selected = 'a_script_with_a_rather_long_name.py';
      await expectCleanLayout(tester, ScriptsApplet(model), display: display);
    }, variant: onDevice);
    testWidgets('the editor on ${display.name}', (tester) async {
      final model = ScriptsModel()
        ..selected = 'hello.py'
        ..editing = true;
      await expectCleanLayout(tester, ScriptsApplet(model), display: display);
    }, variant: onDevice);
    testWidgets('the editor with its keyboard up on ${display.name}', (tester) async {
      final model = ScriptsModel()
        ..selected = 'hello.py'
        ..editing = true;
      await expectCleanLayout(tester, ScriptsApplet(model), display: display, setUp: (t) async {
        await t.tap(find.byType(TextField));
        await t.pump();
      });
    }, variant: onDevice);
    testWidgets('a new script name on ${display.name}', (tester) async {
      await expectCleanLayout(tester, ScriptsApplet(ScriptsModel()..naming = true), display: display);
    }, variant: onDevice);
    testWidgets("a script's own screen on ${display.name}", (tester) async {
      final model = ScriptsModel()
        ..start('counter.py')
        ..drawn = const ScriptScreen('A counter with a rather long title', [
          ScriptItem.text('Pressed 12 times since the script started, which is a sentence that wraps.'),
          ScriptItem.row('Press', tap: 'press'),
          ScriptItem.row('Mode', value: 'Counting up', tap: 'mode'),
          ScriptItem.row('Reset', tap: 'reset'),
        ]);
      await expectCleanLayout(tester, ScriptsApplet(model), display: display);
    }, variant: onDevice);
    testWidgets('a script with a screen showing its output on ${display.name}', (tester) async {
      final model = ScriptsModel()
        ..start('counter.py')
        ..add('starting\n')
        ..drawn = const ScriptScreen('Counter', [ScriptItem.row('Press', tap: 'press')])
        ..output = true;
      await expectCleanLayout(tester, ScriptsApplet(model), display: display);
    }, variant: onDevice);
    testWidgets('in the background on ${display.name}', (tester) async {
      final model = ScriptsModel()
        ..showRunning = true
        ..background = const [
          ScriptUnit(script: 'blink.py', state: ScriptUnitState.running),
          ScriptUnit(script: 'a_script_with_a_rather_long_name.py', state: ScriptUnitState.failing, restarts: 12),
          ScriptUnit(script: 'gone.py', state: ScriptUnitState.failed, restarts: 5),
        ];
      await expectCleanLayout(tester, ScriptsApplet(model), display: display);
    }, variant: onDevice);
    testWidgets('nothing in the background on ${display.name}', (tester) async {
      await expectCleanLayout(tester, ScriptsApplet(ScriptsModel()..showRunning = true), display: display);
    }, variant: onDevice);
    testWidgets('a script running in the background on ${display.name}', (tester) async {
      final model = ScriptsModel()
        ..selected = 'blink.py'
        ..background = const [ScriptUnit(script: 'blink.py', state: ScriptUnitState.running)];
      await expectCleanLayout(tester, ScriptsApplet(model), display: display);
    }, variant: onDevice);
    testWidgets('an input line on ${display.name}', (tester) async {
      final model = ScriptsModel()
        ..start(replName)
        ..typing = true;
      await expectCleanLayout(tester, ScriptsApplet(model), display: display);
    }, variant: onDevice);
  }
}
