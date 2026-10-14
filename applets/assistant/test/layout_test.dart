import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_check/vrx_check.dart';
import 'package:vrx_kit/vrx_kit.dart';

import 'package:assistant_applet/main.dart';
import 'package:assistant_applet/state.dart';

AssistantModel ready() => AssistantModel()..canSpeak = true;

/// The Assistant's screens hold on every display vrx drives (vrx_check).
void main() {
  final turns = [
    const ChatTurn(ChatRole.user, 'What is the tallest mountain in the world?'),
    const ChatTurn(ChatRole.assistant,
        'Mount Everest, on the border of Nepal and China, is the tallest above sea level at 8,849 metres. Mauna Kea is taller measured from its base on the ocean floor.'),
  ];
  for (final display in allDisplays) {
    testWidgets('assistant without speech on ${display.name}', (tester) async {
      await expectCleanLayout(tester, AssistantApplet(AssistantModel()), display: display);
    });
    testWidgets('assistant empty conversation on ${display.name}', (tester) async {
      await expectCleanLayout(tester, AssistantApplet(ready()), display: display);
    });
    testWidgets('assistant conversation on ${display.name}', (tester) async {
      await expectCleanLayout(tester, AssistantApplet(ready()..turns = turns), display: display);
    });
    testWidgets('assistant writing an answer on ${display.name}', (tester) async {
      final m = ready()
        ..turns = turns.sublist(0, 1)
        ..generating = true
        ..partial = 'Mount Everest, on the border';
      await expectCleanLayout(tester, AssistantApplet(m), display: display);
    });
    testWidgets('assistant listening, with a notice, on ${display.name}', (tester) async {
      final m = ready()
        ..listening = true
        ..notice = heardSentence('nothing-heard');
      await expectCleanLayout(tester, AssistantApplet(m), display: display);
    });
    testWidgets('assistant typing on ${display.name}', (tester) async {
      await expectCleanLayout(tester, AssistantApplet(ready()..typing = true), display: display);
    });
  }
}
