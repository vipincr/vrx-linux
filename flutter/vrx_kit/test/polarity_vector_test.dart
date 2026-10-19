// The polarity key has one definition (CNX-01, review 2026-10-17):
// vectors/polarity.json. This test runs the layer's snapshot hook
// verbatim (paths overridden into a temp dir), reads its output through
// bootColors, and holds both to the vector: the key the hook greps, the
// words it may carry, and the dark/light reading bootColors makes of
// them. Renaming the key in the hook, the kit or the vector fails here,
// which is the point of a crossing test.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:vrx_kit/applet.dart';

void main() {
  final vector =
      jsonDecode(File('../../vectors/polarity.json').readAsStringSync())
          as Map<String, dynamic>;
  final key = vector['key'] as String;
  final words = (vector['values'] as List).cast<String>();
  final hook = File(
      '../../layer/recipes-core/vrx-theme/files/vrx-theme-snapshot');

  test('the snapshot hook and bootColors agree with the vector', () {
    final dir = Directory.systemTemp.createTempSync('vrx-polarity');
    addTearDown(() => dir.deleteSync(recursive: true));
    final defaults = File('${dir.path}/theme-default.conf')
      ..writeAsStringSync('scheme=12\n$key=${words.first}\n');
    final settings = File('${dir.path}/settings.conf');
    final out = '${dir.path}/theme.conf';

    void runHook() => Process.runSync('sh', [hook.path], environment: {
          'VRX_THEME_DEFAULTS': defaults.path,
          'VRX_THEME_SETTINGS': settings.path,
          'VRX_THEME_OUT': out,
        });

    // the hook greps the vector's key: its source names it and the
    // scheme's, nothing else
    final hookText = hook.readAsStringSync();
    expect(hookText, contains("^(scheme|$key)="),
        reason: 'the hook greps the vector\'s key');

    // the person's choice wins over the default (last key wins)
    settings.writeAsStringSync('$key=${words.last}\n');
    runHook();
    var colors = bootColors(
        classFile: '${dir.path}/absent-class', themeFile: out);
    expect(colors.dark, isFalse,
        reason: '${words.last} reads light through bootColors');

    settings.writeAsStringSync('$key=${words.first}\n');
    runHook();
    colors =
        bootColors(classFile: '${dir.path}/absent-class', themeFile: out);
    expect(colors.dark, isTrue,
        reason: '${words.first} reads dark through bootColors');

    // a word the vector does not carry is the hook's to refuse: the grep
    // is keyed, so a stray word in the settings file never reaches the
    // theme as one
    settings.writeAsStringSync('$key=sideways\n');
    runHook();
    final carried = File(out).readAsStringSync();
    expect(carried, isNot(contains('sideways')),
        reason: 'the hook carries only lines the vector\'s keys spell');
  });
}
