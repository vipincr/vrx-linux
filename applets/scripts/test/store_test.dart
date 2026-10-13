import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

import 'package:scripts_applet/state.dart';

void main() {
  test('a run opens the console and keeps only the last lines', () {
    final model = ScriptsModel()..scripts = ['hello.py'];
    final h = StoreHarness(model);
    model.start('hello.py');
    model.add('${List.generate(consoleLines + 20, (i) => 'line $i').join('\n')}\n');
    h.dispatch(ScriptsAction.output);
    h.assertView((v) => v.open == 'hello.py' && v.running && v.lines.length == consoleLines && v.lines.last == 'line ${consoleLines + 19}');
    model
      ..running = false
      ..exit = 0;
    h.dispatch(ScriptsAction.ended);
    h.assertView((v) => !v.running && v.exit == 0);
    h.dispatch(ScriptsAction.closed);
    h.assertView((v) => v.open == null && v.lines.isEmpty);
  });

  test("a new script's file name is safe; back goes one step at a time", () {
    expect(ScriptsModel.fileNameFor(' my script '), 'my_script.py');
    expect(ScriptsModel.fileNameFor('blink.py'), 'blink.py');
    expect(ScriptsModel.fileNameFor('../../etc/passwd'), 'etc_passwd.py');
    expect(ScriptsModel.fileNameFor('...'), '');
    final m = ScriptsModel()
      ..selected = 'a.py'
      ..editing = true;
    expect(m.back(), isTrue);
    expect((m.editing, m.selected), (false, 'a.py'));
    expect(m.back(), isTrue);
    expect(m.selected, isNull);
    expect(m.back(), isFalse, reason: 'at the list Back leaves the applet');
  });
}
