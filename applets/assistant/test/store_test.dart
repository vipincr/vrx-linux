import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

import 'package:assistant_applet/state.dart';

const chat = LocalModel(name: 'chat', title: 'Chat', file: 'q.gguf', size: 500000000, licence: 'Apache-2.0');
const speech = LocalModel(name: 'speech', title: 'Speech', file: 'w.bin', size: 30000000, licence: 'MIT');

void main() {
  test('ready only when every model it needs is here; the size still to come', () {
    final m = AssistantModel()..needed = [chat, speech];
    final h = StoreHarness(m);
    h.assertView((v) => !v.ready && v.missing == 530000000 && !v.fetching);
    m.progress = {
      'chat': const ModelProgress(ModelState.present),
      'speech': const ModelProgress(ModelState.fetching, bytes: 10000000),
    };
    h.dispatch(AssistantAction.progress);
    h.assertView((v) => !v.ready && v.fetching && v.missing == 20000000 && v.fetched == 10000000);
    m.progress['speech'] = const ModelProgress(ModelState.present);
    h.dispatch(AssistantAction.progress);
    h.assertView((v) => v.ready && v.missing == 0);
  });

  test('no models listed is never ready; speaking needs a microphone and the models', () {
    final h = StoreHarness(AssistantModel());
    h.assertView((v) => !v.ready && !v.canSpeak);
    final m = AssistantModel()
      ..needed = [chat]
      ..canSpeak = true;
    final h2 = StoreHarness(m);
    h2.assertView((v) => !v.canSpeak, because: 'not before the models are here');
    m.progress = {'chat': const ModelProgress(ModelState.present)};
    h2.dispatch(AssistantAction.models);
    h2.assertView((v) => v.canSpeak);
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

  test('every reason has a sentence; sizes read in MB', () {
    expect(heardSentence('nothing-heard'), 'Nothing was heard.');
    expect(heardSentence('no-microphone'), 'This device has no microphone.');
    expect(heardSentence('engine'), endsWith('in the log.'));
    expect(heardSentence(null), endsWith('in the log.'));
    for (final why in ['network', 'checksum', 'space', null]) {
      expect(fetchSentence(why), endsWith('.'));
    }
    expect(megabytes(523566187), '524 MB');
  });
}
