import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

import 'package:assistant_applet/state.dart';

void main() {
  test('speaking is offered only where speech is built in and the device can hear', () {
    StoreHarness(AssistantModel()).assertView((v) => !v.canSpeak && v.turns.isEmpty);
    final m = AssistantModel()..canSpeak = true;
    final h = StoreHarness(m);
    h.dispatch(AssistantAction.ready);
    h.assertView((v) => v.canSpeak);
  });

  test('back leaves typing; clear empties the conversation and its notice', () {
    final m = AssistantModel()
      ..typing = true
      ..turns = [const ChatTurn(ChatRole.user, 'hi')]
      ..notice = 'x';
    final h = StoreHarness(m);
    h.dispatch(AssistantAction.back);
    h.assertView((v) => !v.typing && v.turns.length == 1);
    h.dispatch(AssistantAction.cleared);
    h.assertView((v) => v.turns.isEmpty && v.notice == null);
  });

  test('a new question or listening clears the last notice', () {
    final m = AssistantModel()..notice = 'Nothing was heard.';
    final h = StoreHarness(m);
    h.dispatch(AssistantAction.listening);
    h.assertView((v) => v.notice == null);
  });

  test('preparing to listen clears the notice and is not yet listening', () {
    final m = AssistantModel()
      ..notice = 'Nothing was heard.'
      ..preparing = true;
    final h = StoreHarness(m);
    h.dispatch(AssistantAction.preparing);
    h.assertView((v) => v.preparing && !v.listening && v.notice == null);
  });

  test('every reason stt gives has a sentence', () {
    expect(heardSentence('nothing-heard'), 'Nothing was heard.');
    expect(heardSentence('no-microphone'), 'This device has no microphone.');
    expect(heardSentence('engine'), endsWith('in the log.'));
    expect(heardSentence(null), endsWith('in the log.'));
  });
}
