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
}
