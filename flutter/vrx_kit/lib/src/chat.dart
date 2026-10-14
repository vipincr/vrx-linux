/// The local models, from an applet (plan 0011 D18): chat with
/// llama-server, and whether speech can be written down here.
///
/// Linux and the engines provide everything underneath. llama-server
/// speaks OpenAI's chat API over HTTP; systemd starts it on the first
/// connection to /run/vrx-ml/llm.sock (the ml grant's group) and stops it
/// when idle. A model is an opt-in recipe in the image (meta-vrx,
/// VRX_ML_MODELS), never a download on the device: an applet that needs a
/// model ships only in an image that has it. This file is the vrx
/// interface over those: no server, no protocol of its own.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Who said it.
enum ChatRole { user, assistant }

class ChatTurn {
  const ChatTurn(this.role, this.text);

  final ChatRole role;
  final String text;
}

/// Why a reply did not come, in a person's words (plan 0011 D2).
class LocalChatError implements Exception {
  const LocalChatError(this.sentence, [this.detail]);

  final String sentence;

  /// For the log, never the screen.
  final Object? detail;

  static const notRunning = LocalChatError('The assistant could not start its model. The details are in the log.');
  static const cutShort = LocalChatError('The answer was cut short.');

  @override
  String toString() => 'LocalChatError($sentence${detail == null ? '' : ': $detail'})';
}

/// Chat with the local model through llama-server's OpenAI-compatible
/// `/v1/chat/completions`, streamed, on the unix socket.
class LocalChat {
  LocalChat({this.socketPath = '/run/vrx-ml/llm.sock'});

  final String socketPath;

  /// What the model is told before the conversation: short answers, for a
  /// small screen.
  static const system = 'You are a helpful assistant on a small device with a small screen. '
      'Answer in a few short sentences.';

  /// The last turns sent: the context is 2048 tokens.
  static const keepTurns = 8;

  /// The reply to [turns], as it is written, piece by piece. Cancelling the
  /// subscription stops the model.
  Stream<String> reply(List<ChatTurn> turns, {int maxTokens = 256}) {
    final client = HttpClient()
      ..connectionFactory = (uri, proxyHost, proxyPort) =>
          Socket.startConnect(InternetAddress(socketPath, type: InternetAddressType.unix), 0);
    late StreamController<String> out;
    StreamSubscription<String>? lines;
    Future<void> run() async {
      try {
        final req = await client.postUrl(Uri.parse('http://localhost/v1/chat/completions'));
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(chatRequest(turns, maxTokens: maxTokens)));
        final res = await req.close();
        if (res.statusCode != 200) {
          throw LocalChatError(LocalChatError.notRunning.sentence, 'HTTP ${res.statusCode}');
        }
        var done = false;
        final finished = Completer<void>();
        lines = res.transform(utf8.decoder).transform(const LineSplitter()).listen(
          (line) {
            final event = chatEvent(line);
            if (event == null) return;
            if (event.done) done = true;
            if (event.text.isNotEmpty && !out.isClosed) out.add(event.text);
          },
          onError: (Object err) => finished.isCompleted ? null : finished.completeError(err),
          onDone: () => finished.isCompleted ? null : finished.complete(),
        );
        await finished.future;
        // the server went away mid-answer (killed, out of memory)
        if (!done && !out.isClosed) out.addError(LocalChatError.cutShort);
      } on LocalChatError catch (err) {
        if (!out.isClosed) out.addError(err);
      } on Object catch (err) {
        debugPrint('chat: $err');
        if (!out.isClosed) out.addError(LocalChatError(LocalChatError.notRunning.sentence, err));
      } finally {
        client.close(force: true);
        if (!out.isClosed) await out.close();
      }
    }

    out = StreamController<String>(
      onListen: () => unawaited(run()),
      onCancel: () async {
        await lines?.cancel();
        client.close(force: true);
      },
    );
    return out.stream;
  }
}

/// The request body for [turns].
Map<String, Object?> chatRequest(List<ChatTurn> turns, {int maxTokens = 256}) {
  final kept = turns.length > LocalChat.keepTurns ? turns.sublist(turns.length - LocalChat.keepTurns) : turns;
  return {
    'messages': [
      {'role': 'system', 'content': LocalChat.system},
      for (final t in kept) {'role': t.role.name, 'content': t.text},
    ],
    'stream': true,
    'max_tokens': maxTokens,
  };
}

/// One server-sent line: its piece of text, and whether the answer ended.
({String text, bool done})? chatEvent(String line) {
  if (!line.startsWith('data:')) return null;
  final data = line.substring(5).trim();
  if (data == '[DONE]') return (text: '', done: true);
  try {
    final j = jsonDecode(data) as Map<String, dynamic>;
    final choice = (j['choices'] as List?)?.firstOrNull as Map<String, dynamic>?;
    if (choice == null) return null;
    final delta = choice['delta'] as Map<String, dynamic>?;
    return (text: (delta?['content'] as String?) ?? '', done: choice['finish_reason'] != null);
  } on Object {
    return null;
  }
}

/// Whether the board can hear: a capture device in ALSA's PCM list
/// ("00-00: name : name : playback 1 : capture 1").
Future<bool> hasMicrophone({String pcm = '/proc/asound/pcm'}) async {
  try {
    return microphoneIn(await File(pcm).readAsString());
  } on FileSystemException {
    return false;
  }
}

bool microphoneIn(String pcmList) => pcmList.split('\n').any((l) => l.contains(': capture '));

/// Whether this image writes speech down: the speech model's socket
/// exists only where a speech model was built in (vrx-ml-speech).
Future<bool> speechInstalled({String socket = '/run/vrx-ml/stt.sock'}) async =>
    await FileSystemEntity.type(socket) == FileSystemEntityType.unixDomainSock;
