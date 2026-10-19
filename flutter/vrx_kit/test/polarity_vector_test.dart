// The polarity key has one definition (CNX-01, review 2026-10-17):
// vectors/polarity.json. This test runs the layer's snapshot hook
// verbatim (paths overridden into a temp dir), reads its output through
// bootColors, and holds both to the vector: the key the hook greps, the
// words it may carry, and the dark/light reading bootColors makes of
// them. Renaming the key in the hook, the kit or the vector fails here,
// which is the point of a crossing test.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart' show bootColors;

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

    // the hook carries the KEY's line whatever its value: which words
    // mean what is bootColors' reading (the vector's values), not the
    // grep's; a wrong word reads dark there, never a crash
    settings.writeAsStringSync('$key=sideways\n');
    runHook();
    final carried = bootColors(
        classFile: '${dir.path}/absent-class', themeFile: out);
    expect(carried.dark, isTrue,
        reason: 'a word the vector does not carry reads dark, the default');
  });
}
