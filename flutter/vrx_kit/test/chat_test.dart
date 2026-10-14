import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

void main() {
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

  test('speech is installed where its socket is, and nowhere else', () async {
    final dir = await Directory.systemTemp.createTemp('vrx-ml');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/stt.sock';
    expect(await speechInstalled(socket: path), isFalse, reason: 'no speech model in this image');
    await File(path).writeAsString('');
    expect(await speechInstalled(socket: path), isFalse, reason: 'a plain file is not the socket');
    await File(path).delete();
    final server = await ServerSocket.bind(InternetAddress(path, type: InternetAddressType.unix), 0);
    addTearDown(server.close);
    expect(await speechInstalled(socket: path), isTrue);
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
