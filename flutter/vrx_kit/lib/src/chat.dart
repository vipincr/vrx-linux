/// The local models, from an applet (plan 0011 D18): chat with
/// llama-server, the models list, and the download a person agrees to.
///
/// Linux and the engines provide everything underneath. llama-server
/// speaks OpenAI's chat API over HTTP; systemd starts it on the first
/// connection to /run/vrx-ml/llm.sock (the ml grant's group) and stops it
/// when idle; vrx-ml-fetch.path downloads a model when a file named after
/// it appears in /var/lib/vrx-ml/wanted. This file is the vrx interface
/// over those: no server, no protocol of its own.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'ticker.dart';

/// One model the image lists in /usr/share/vrx-ml/models.toml.
class LocalModel {
  const LocalModel({
    required this.name,
    required this.title,
    required this.file,
    required this.size,
    required this.licence,
  });

  /// Its section in the list ("chat", "speech"): how an applet names it.
  final String name;
  final String title;
  final String file;

  /// Bytes, as downloaded.
  final int size;
  final String licence;
}

/// Where a model's download stands, from vrx-ml-fetch's status file and
/// the partial file's size.
enum ModelState { absent, fetching, stopped, failed, present }

class ModelProgress {
  const ModelProgress(this.state, {this.bytes = 0, this.why});

  final ModelState state;

  /// Bytes downloaded so far (while fetching or stopped).
  final int bytes;

  /// Why it failed: network, checksum, space.
  final String? why;

  @override
  bool operator ==(Object other) =>
      other is ModelProgress && other.state == state && other.bytes == bytes && other.why == why;

  @override
  int get hashCode => Object.hash(state, bytes, why);

  @override
  String toString() => 'ModelProgress($state, $bytes${why == null ? '' : ', $why'})';
}

/// The models list and the downloads.
class LocalModels {
  LocalModels({
    this.listPath = '/usr/share/vrx-ml/models.toml',
    this.root = '/var/lib/vrx-ml',
  });

  final String listPath;
  final String root;

  /// The models the image lists; empty where it lists none (no ML stack).
  Future<List<LocalModel>> list() async {
    try {
      return parseModels(await File(listPath).readAsString());
    } on FileSystemException {
      return const [];
    }
  }

  /// Where the model is now.
  Future<ModelProgress> progress(LocalModel m) async {
    if (await File('$root/models/${m.file}').exists()) return const ModelProgress(ModelState.present);
    final part = File('$root/models/${m.file}.part');
    final bytes = await part.exists() ? await part.length() : 0;
    final wanted = await File('$root/wanted/${m.name}').exists();
    final status = await _status(m.name);
    final state = status['state'];
    if (wanted) return ModelProgress(ModelState.fetching, bytes: bytes);
    if (state == 'failed') return ModelProgress(ModelState.failed, bytes: bytes, why: status['why'] ?? 'unknown');
    if (state == 'stopped' || bytes > 0) return ModelProgress(ModelState.stopped, bytes: bytes);
    return const ModelProgress(ModelState.absent);
  }

  Future<Map<String, String>> _status(String name) async {
    try {
      final out = <String, String>{};
      for (final line in await File('$root/status/$name').readAsLines()) {
        final eq = line.indexOf('=');
        if (eq > 0) out[line.substring(0, eq)] = line.substring(eq + 1).trim();
      }
      return out;
    } on FileSystemException {
      return const {};
    }
  }

  /// Ask for [m]: the person agreed. vrx-ml-fetch takes it from here.
  Future<void> fetch(LocalModel m) => File('$root/wanted/${m.name}').writeAsString('');

  /// Stop fetching [m]; what came is kept for the next try.
  Future<void> stop(LocalModel m) async {
    final f = File('$root/wanted/${m.name}');
    if (await f.exists()) await f.delete();
  }

  /// [m]'s progress once a second while the applet is in front, and once
  /// at once; a new value only when it changed.
  Stream<ModelProgress> watch(LocalModel m) {
    late StreamController<ModelProgress> out;
    VrxTicker? ticker;
    ModelProgress? last;
    Future<void> read() async {
      final p = await progress(m);
      if (p != last && !out.isClosed) out.add(last = p);
    }

    out = StreamController<ModelProgress>(
      onListen: () {
        unawaited(read());
        ticker = VrxTicker(const Duration(seconds: 1), () => unawaited(read()));
      },
      onCancel: () async {
        ticker?.cancel();
        await out.close();
      },
    );
    return out.stream;
  }
}

/// The models list's grammar: `[name]` sections of `key = "text"` or
/// `key = number`, `#` comments. vrx-ml-fetch reads the same file.
List<LocalModel> parseModels(String text) {
  final sections = <String, Map<String, String>>{};
  String? current;
  for (final raw in const LineSplitter().convert(text)) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    if (line.startsWith('[') && line.endsWith(']')) {
      current = line.substring(1, line.length - 1).trim();
      sections[current] = {};
      continue;
    }
    final eq = line.indexOf('=');
    if (current == null || eq < 0) continue;
    var value = line.substring(eq + 1).trim();
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) value = value.substring(1, value.length - 1);
    sections[current]![line.substring(0, eq).trim()] = value;
  }
  return [
    for (final MapEntry(key: name, value: s) in sections.entries)
      if (s['file'] != null && int.tryParse(s['size'] ?? '') != null)
        LocalModel(name: name, title: s['title'] ?? name, file: s['file']!, size: int.parse(s['size']!), licence: s['licence'] ?? ''),
  ];
}

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
