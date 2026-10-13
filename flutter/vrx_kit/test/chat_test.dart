import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

const list = '''
# a comment
[chat]
title = "Chat: Qwen2.5 0.5B Instruct"
file = "qwen2.5-0.5b-instruct-q4_k_m.gguf"
url = "https://example.org/q.gguf"
sha256 = "74a4"
size = 491400032
licence = "Apache-2.0"

[speech]
file = "ggml-tiny.en-q5_1.bin"
size = 32166155

[broken]
title = "no file, no size"
''';

void main() {
  test('the models list: sections with a file and a size; the rest skipped', () {
    final m = parseModels(list);
    expect(m.map((e) => e.name), ['chat', 'speech']);
    expect(m.first.title, 'Chat: Qwen2.5 0.5B Instruct');
    expect(m.first.size, 491400032);
    expect(m.first.licence, 'Apache-2.0');
    expect(m.last.title, 'speech', reason: 'a model without a title is named by its section');
  });

  test('server-sent lines: pieces, the end, and noise ignored', () {
    expect(chatEvent('data: {"choices":[{"delta":{"content":"Hel"},"finish_reason":null}]}'), (text: 'Hel', done: false));
    expect(chatEvent('data: {"choices":[{"delta":{},"finish_reason":"stop"}]}'), (text: '', done: true));
    expect(chatEvent('data: [DONE]'), (text: '', done: true));
    expect(chatEvent(''), isNull);
    expect(chatEvent(': keep-alive'), isNull);
    expect(chatEvent('data: not json'), isNull);
  });

  test('a request keeps the system line and the last eight turns', () {
    final turns = [for (var i = 0; i < 11; i++) ChatTurn(i.isEven ? ChatRole.user : ChatRole.assistant, 't$i')];
    final body = chatRequest(turns);
    final messages = body['messages']! as List;
    expect(messages.length, 1 + LocalChat.keepTurns);
    expect((messages.first as Map)['role'], 'system');
    expect((messages[1] as Map)['content'], 't3');
    expect((messages.last as Map)['content'], 't10');
    expect(body['stream'], true);
  });

  test('a microphone is a capture line in ALSA\'s list', () {
    expect(microphoneIn('00-00: MAI PCM i2s-hifi-0 : MAI PCM i2s-hifi-0 : playback 1\n'), isFalse);
    expect(microphoneIn('00-00: USB Audio : USB Audio : playback 1 : capture 1\n'), isTrue);
  });

  group('downloads', () {
    late Directory root;
    late LocalModels models;
    final chat = parseModels(list).first;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('vrx-ml');
      for (final d in ['models', 'status', 'wanted']) {
        await Directory('${root.path}/$d').create();
      }
      models = LocalModels(root: root.path);
    });
    tearDown(() => root.delete(recursive: true));

    test('absent, asked for, partly there, failed, present', () async {
      expect((await models.progress(chat)).state, ModelState.absent);
      await models.fetch(chat);
      await File('${root.path}/models/${chat.file}.part').writeAsBytes(List.filled(10, 0));
      expect(await models.progress(chat), const ModelProgress(ModelState.fetching, bytes: 10));
      await models.stop(chat);
      expect((await models.progress(chat)).state, ModelState.stopped, reason: 'what came is kept');
      await File('${root.path}/status/chat').writeAsString('state=failed\nwhy=checksum\n');
      expect(await models.progress(chat), const ModelProgress(ModelState.failed, bytes: 10, why: 'checksum'));
      await File('${root.path}/models/${chat.file}').writeAsString('');
      expect((await models.progress(chat)).state, ModelState.present);
    });
  });

  group('a reply through the socket', () {
    late Directory dir;
    late HttpServer server;
    late String socket;

    Future<void> serve(void Function(HttpResponse res) answer) async {
      dir = await Directory.systemTemp.createTemp('vrx-chat');
      socket = '${dir.path}/llm.sock';
      server = await HttpServer.bind(InternetAddress(socket, type: InternetAddressType.unix), 0);
      server.listen((req) async {
        final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map<String, dynamic>;
        expect(body['stream'], true);
        answer(req.response);
      });
    }

    tearDown(() async {
      await server.close(force: true);
      await dir.delete(recursive: true);
    });

    test('the pieces arrive in order and the stream ends', () async {
      await serve((res) async {
        res.headers.contentType = ContentType('text', 'event-stream');
        for (final piece in ['Hel', 'lo.']) {
          res.write('data: ${jsonEncode({
                'choices': [
                  {'delta': {'content': piece}, 'finish_reason': null}
                ]
              })}\n\n');
        }
        res.write('data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n');
        await res.close();
      });
      final text = await LocalChat(socketPath: socket).reply(const [ChatTurn(ChatRole.user, 'Hi')]).join();
      expect(text, 'Hello.');
    });

    test('a server that stops mid-answer is said as cut short', () async {
      await serve((res) async {
        res.write('data: {"choices":[{"delta":{"content":"Half"},"finish_reason":null}]}\n\n');
        await res.close();
      });
      final got = <String>[];
      Object? error;
      await LocalChat(socketPath: socket)
          .reply(const [ChatTurn(ChatRole.user, 'Hi')])
          .handleError((Object e) => error = e)
          .forEach(got.add);
      expect(got, ['Half']);
      expect((error! as LocalChatError).sentence, LocalChatError.cutShort.sentence);
    });

    test('no server: a sentence, never an exception\'s text', () async {
      dir = await Directory.systemTemp.createTemp('vrx-chat');
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      Object? error;
      await LocalChat(socketPath: '${dir.path}/absent.sock')
          .reply(const [ChatTurn(ChatRole.user, 'Hi')])
          .handleError((Object e) => error = e)
          .drain<void>();
      expect((error! as LocalChatError).sentence, LocalChatError.notRunning.sentence);
    });
  });
}
