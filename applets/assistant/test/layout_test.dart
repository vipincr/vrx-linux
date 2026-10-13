import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_check/vrx_check.dart';
import 'package:vrx_kit/vrx_kit.dart';

import 'package:assistant_applet/main.dart';
import 'package:assistant_applet/state.dart';

const chat = LocalModel(name: 'chat', title: 'Chat', file: 'q.gguf', size: 491400032, licence: 'Apache-2.0');
const speech = LocalModel(name: 'speech', title: 'Speech', file: 'w.bin', size: 32166155, licence: 'MIT');

AssistantModel ready() => AssistantModel()
  ..needed = [chat, speech]
  ..canSpeak = true
  ..progress = {'chat': const ModelProgress(ModelState.present), 'speech': const ModelProgress(ModelState.present)};

/// The Assistant's screens hold on every display vrx drives (vrx_check).
void main() {
  final turns = [
    const ChatTurn(ChatRole.user, 'What is the tallest mountain in the world?'),
    const ChatTurn(ChatRole.assistant,
        'Mount Everest, on the border of Nepal and China, is the tallest above sea level at 8,849 metres. Mauna Kea is taller measured from its base on the ocean floor.'),
  ];
  for (final display in allDisplays) {
    testWidgets('assistant asks for its models on ${display.name}', (tester) async {
      await expectCleanLayout(tester, AssistantApplet(AssistantModel()..needed = [chat, speech]), display: display);
    });
    testWidgets('assistant downloading on ${display.name}', (tester) async {
      final m = AssistantModel()
        ..needed = [chat, speech]
        ..progress = {'chat': const ModelProgress(ModelState.fetching, bytes: 120000000)};
      await expectCleanLayout(tester, AssistantApplet(m), display: display);
    });
    testWidgets('assistant download failed on ${display.name}', (tester) async {
      final m = AssistantModel()
        ..needed = [chat]
        ..progress = {'chat': const ModelProgress(ModelState.failed, bytes: 1000, why: 'checksum')}
        ..notice = fetchSentence('checksum');
      await expectCleanLayout(tester, AssistantApplet(m), display: display);
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
