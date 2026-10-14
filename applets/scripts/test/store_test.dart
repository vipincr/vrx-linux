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
}
