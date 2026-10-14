import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

import 'package:scripts_applet/state.dart';

void main() {
  test('a run opens the console and keeps only the last lines', () {
    final model = ScriptsModel();
    final h = StoreHarness(model)
      ..dispatch(const ScriptsListed(scripts: ['hello.py']))
      ..dispatch(const ScriptsStarted('hello.py'))
      ..dispatch(ScriptsOutput('${List.generate(consoleLines + 20, (i) => 'line $i').join('\n')}\n'));
    h.assertView((v) => v.open == 'hello.py' && v.running && v.lines.length == consoleLines && v.lines.last == 'line ${consoleLines + 19}');
    h.dispatch(const ScriptsSent('x'));
    h.assertView((v) => v.lines.last == '> x');
    h.dispatch(const ScriptsEnded(exit: 0));
    h.assertView((v) => !v.running && v.exit == 0);
    h.verify(
      fresh: ScriptsModel.new,
      probes: const [ScriptsAction.back, ScriptsAction.closed, ScriptsAction.typing, ScriptsAction.naming, ScriptsSelect('hello.py')],
    );
    h.dispatch(ScriptsAction.closed);
    h.assertView((v) => v.open == null && v.lines.isEmpty);
  });

  test("a new script's file name is safe; back goes one step at a time", () {
    expect(ScriptsModel.fileNameFor(' my script '), 'my_script.py');
    expect(ScriptsModel.fileNameFor('blink.py'), 'blink.py');
    expect(ScriptsModel.fileNameFor('../../etc/passwd'), 'etc_passwd.py');
    expect(ScriptsModel.fileNameFor('...'), '');
    final m = ScriptsModel();
    final h = StoreHarness(m)..dispatch(const ScriptsEdit('a.py'));
    expect(m.atRoot, isFalse);
    h.dispatch(ScriptsAction.back);
    expect((m.editing, m.selected), (false, 'a.py'));
    h.dispatch(ScriptsAction.back);
    expect(m.selected, isNull);
    expect(m.atRoot, isTrue, reason: 'at the list Back leaves the applet');
    h.verify(fresh: ScriptsModel.new, probes: const [ScriptsAction.back]);
  });

  test('a line that is a screen draws it; any other line is output', () {
    expect(ScriptScreen.parse('hello'), isNull);
    expect(ScriptScreen.parse('{"not": "a screen"}'), isNull);
    expect(ScriptScreen.parse('{"screen": [oops'), isNull, reason: 'broken JSON is printed output');
    final cleared = ScriptScreen.parse('{"screen": null}');
    expect(cleared, isNotNull);
    expect(cleared!.screen, isNull);
    final drawn = ScriptScreen.parse(
        '{"screen": [{"text": "Pressed 2 times."}, {"row": "Press", "tap": "press"}, {"row": "Mode", "value": 3}, 7], "title": "Counter"}')!;
    expect(drawn.screen!.title, 'Counter');
    expect(drawn.screen!.items, const [
      ScriptItem.text('Pressed 2 times.'),
      ScriptItem.row('Press', tap: 'press'),
      ScriptItem.row('Mode', value: '3'),
    ], reason: 'a value is shown as text; an item that is no row or text is left out');
    final many = '{"screen": [${List.filled(80, '{"row": "r"}').join(',')}]}';
    expect(ScriptScreen.parse(many)!.screen!.items.length, ScriptScreen.most);
    expect(tapLine('press'), '{"tap":"press"}');
  });

  test("a script's screen, its output, and back to the list", () {
    final m = ScriptsModel();
    const screen = ScriptScreen('Counter', [ScriptItem.row('Press', tap: 'press')]);
    final h = StoreHarness(m)
      ..dispatch(const ScriptsStarted('counter.py'))
      ..dispatch(const ScriptsScreen(screen));
    h.assertView((v) => v.screen == screen && !v.output);
    h.dispatch(ScriptsAction.output);
    h.assertView((v) => v.output && v.screen == screen);
    h.dispatch(const ScriptsScreen(screen));
    // a new screen is shown
    h.assertView((v) => !v.output);
    h.dispatch(const ScriptsScreen(null));
    h.assertView((v) => v.screen == null);
    h.dispatch(const ScriptsScreen(screen));
    h.dispatch(const ScriptsStarted('counter.py'));
    // a new run starts at its output
    h.assertView((v) => v.screen == null);
    h.verify(
      fresh: ScriptsModel.new,
      probes: const [ScriptsScreen(screen), ScriptsScreen(null), ScriptsAction.output, ScriptsAction.back, ScriptsAction.closed],
    );
    h.dispatch(ScriptsAction.back);
    expect((m.open, m.screen), (null, null));
  });

  test('what runs in the background, its own screen, and Back', () {
    const units = [
      ScriptUnit(script: 'blink.py', state: ScriptUnitState.running),
      ScriptUnit(script: 'crash.py', state: ScriptUnitState.failing, restarts: 3),
      ScriptUnit(script: 'gone.py', state: ScriptUnitState.failed, restarts: 5),
    ];
    final m = ScriptsModel();
    final h = StoreHarness(m)
      ..dispatch(const ScriptsBackground(units: units))
      ..dispatch(ScriptsAction.running);
    h.assertView((v) => v.showRunning && v.background.length == 3);
    expect(unitWords(units[0]), 'Running');
    expect(unitWords(units[1]), 'Failing, restarted 3 times');
    expect(unitWords(const ScriptUnit(script: 'a.py', state: ScriptUnitState.failing, restarts: 1)), 'Failing, restarted once');
    expect(unitWords(units[2]), 'Stopped after failing');
    expect(m.atRoot, isFalse);
    h.dispatch(const ScriptsBackground(error: 'Stopping blink.py was refused.'));
    // an error keeps the last list
    h.assertView((v) => v.error != null && v.background.length == 3);
    h.verify(
      fresh: ScriptsModel.new,
      probes: const [ScriptsBackground(units: units), ScriptsAction.running, ScriptsAction.back],
    );
    h.dispatch(ScriptsAction.back);
    expect(m.atRoot, isTrue);
    expect(ScriptUnit.instanceFor('blink.py'), 'blink');
    expect(ScriptUnit.instanceFor('my script.py'), isNull);
    expect(ScriptUnit.instanceFor('notes.txt'), isNull);
  });
}
