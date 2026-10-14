import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

import 'package:assistant_applet/state.dart';

void main() {
  test('speaking is offered only where speech is built in and the device can hear', () {
    StoreHarness(AssistantModel()).assertView((v) => !v.canSpeak && v.turns.isEmpty);
    final h = StoreHarness(AssistantModel())..dispatch(const AssistantReady(canSpeak: true));
    h.assertView((v) => v.canSpeak);
  });

  test('back leaves typing; clear empties the conversation and its notice', () {
    final h = StoreHarness(AssistantModel())
      ..dispatch(const AssistantAsk('hi'))
      ..dispatch(const AssistantPiece('hello'))
      ..dispatch(AssistantAction.answered)
      ..dispatch(const AssistantNotice('x'))
      ..dispatch(AssistantAction.typing);
    h.assertView((v) => v.typing && v.turns.length == 2 && v.notice == 'x');
    h.dispatch(AssistantAction.back);
    h.assertView((v) => !v.typing && v.turns.length == 2);
    h.dispatch(AssistantAction.typing);
    h.verify(
      fresh: AssistantModel.new,
      probes: const [AssistantAction.back, AssistantAction.cleared, AssistantAsk(''), AssistantHeard(error: 'engine')],
    );
    h.dispatch(AssistantAction.cleared);
    h.assertView((v) => v.turns.isEmpty && v.notice == null);
  });

  test('a new question or listening clears the last notice', () {
    final h = StoreHarness(AssistantModel())
      ..dispatch(AssistantAction.preparing)
      ..dispatch(const AssistantHeard(error: 'nothing-heard'));
    h.assertView((v) => v.notice == 'Nothing was heard.');
    h
      ..dispatch(AssistantAction.preparing)
      ..dispatch(AssistantAction.recording);
    h.assertView((v) => v.listening && v.notice == null);
    h.dispatch(const AssistantAsk('again'));
    h.assertView((v) => v.generating, because: 'a new question is taken while listening ends by stt');
  });

  test('preparing to listen clears the notice and is not yet listening', () {
    final h = StoreHarness(AssistantModel())
      ..dispatch(const AssistantNotice('Nothing was heard.'))
      ..dispatch(AssistantAction.preparing);
    h.assertView((v) => v.preparing && !v.listening && v.notice == null);
  });

  test('every reason stt gives has a sentence', () {
    expect(heardSentence('nothing-heard'), 'Nothing was heard.');
    expect(heardSentence('no-microphone'), 'This device has no microphone.');
    expect(heardSentence('engine'), endsWith('in the log.'));
    expect(heardSentence(null), endsWith('in the log.'));
  });
}
