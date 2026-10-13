/// The inter-applet bridge from an applet (plan 0008 D15), over vrxhost's
/// io.vrx.Host: channels (streams between two applets, ordered JSON
/// records, one per line) and Listen (the intents this applet handles and
/// the channels others open on it). The streams ride as file descriptors
/// on the Varlink socket, which dart:io's RawSocket messages carry.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'host.dart';

/// A stream between two applets that vrxhost opened.
class VrxChannel {
  VrxChannel(this.name, this.socket);

  /// `<applet>.<channel>`.
  final String name;
  final Socket socket;

  /// Write one JSON record.
  void write(Object? record) =>
      socket.add(utf8.encode('${jsonEncode({'pipe': name, 'record': record})}\n'));

  /// The records the other end writes, until it closes.
  Stream<Object?> get records => socket
      .cast<List<int>>()
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .where((l) => l.isNotEmpty)
      .map((l) => (jsonDecode(l) as Map<String, dynamic>)['record']);
}

/// What vrxhost hands a listening applet.
sealed class VrxDelivery {
  const VrxDelivery();
}

/// An intent this applet handles; with an [id], [VrxBridge.answer] it
/// within 100 ms (silence is a pass).
class VrxIntentDelivery extends VrxDelivery {
  const VrxIntentDelivery({required this.id, required this.name, required this.payload});

  final int? id;
  final String name;
  final Object? payload;
}

/// Another applet opened one of this applet's channels.
class VrxChannelDelivery extends VrxDelivery {
  const VrxChannelDelivery({required this.from, required this.channel});

  final String from;
  final VrxChannel channel;
}

/// Varlink's framing: messages are JSON objects, each ending in a NUL.
/// Bytes go in as they arrive; whole messages come out.
class VarlinkFrames {
  final _pending = <int>[];

  List<Map<String, dynamic>> add(List<int> bytes) {
    final out = <Map<String, dynamic>>[];
    for (final b in bytes) {
      if (b != 0) {
        _pending.add(b);
        continue;
      }
      final message = jsonDecode(utf8.decode(_pending));
      _pending.clear();
      if (message is Map<String, dynamic>) out.add(message);
    }
    return out;
  }
}

/// A Listen reply as a delivery, given the stream that came with it.
/// Null for a reply that is neither (an error is thrown by the caller).
VrxDelivery? deliveryOf(Map<String, dynamic> reply, Socket? Function() stream) {
  final p = (reply['parameters'] as Map<String, dynamic>?) ?? const {};
  switch (p['kind']) {
    case 'intent':
      return VrxIntentDelivery(id: (p['id'] as num?)?.toInt(), name: p['name'] as String? ?? '', payload: p['payload']);
    case 'channel':
      // ignore: close_sinks, the VrxChannel below owns it and the applet closes it
      final socket = stream();
      if (socket == null) return null;
      final from = p['from'] as String? ?? '';
      return VrxChannelDelivery(from: from, channel: VrxChannel('$from.${p['channel'] ?? ''}', socket));
  }
  return null;
}

/// io.vrx.Host's bridge calls.
abstract final class VrxBridge {
  static String socketPath = VarlinkAppletsService.defaultSocket;

  static Future<RawSocket> _connect(String method, Map<String, dynamic> parameters, {bool more = false}) async {
    final socket = await RawSocket.connect(InternetAddress(socketPath, type: InternetAddressType.unix), 0);
    final call = {'method': method, 'parameters': parameters, if (more) 'more': true};
    socket.write([...utf8.encode(jsonEncode(call)), 0]);
    return socket;
  }

  /// Every reply on [socket], each with the descriptors that came with it.
  static Stream<(Map<String, dynamic>, List<ResourceHandle>)> _replies(RawSocket socket) async* {
    final frames = VarlinkFrames();
    final handles = <ResourceHandle>[];
    await for (final event in socket) {
      if (event == RawSocketEvent.closed || event == RawSocketEvent.readClosed) return;
      if (event != RawSocketEvent.read) continue;
      final message = socket.readMessage();
      if (message == null) continue;
      for (final control in message.controlMessages) {
        handles.addAll(control.extractHandles());
      }
      for (final reply in frames.add(message.data)) {
        final error = reply['error'];
        if (error is String) {
          throw VarlinkError(error, (reply['parameters'] as Map<String, dynamic>?) ?? const {});
        }
        final p = (reply['parameters'] as Map<String, dynamic>?) ?? const {};
        // a channel delivery or an Open reply carries the stream's end
        final carries = p['kind'] == 'channel' || !p.containsKey('kind');
        yield (reply, carries && handles.isNotEmpty ? [handles.removeAt(0)] : const <ResourceHandle>[]);
        if (reply['continues'] != true) return;
      }
    }
  }

  /// Open `<to>.<channel>`: it must be in this applet's channels.opens
  /// and the other applet's channels.offers, and that applet listening.
  static Future<VrxChannel> open(String to, String channel) async {
    final socket = await _connect('io.vrx.Host.Open', {'to': to, 'channel': channel});
    try {
      final (_, handles) = await _replies(socket).first;
      if (handles.isEmpty) throw const VarlinkError('io.vrx.Host.Unavailable', {});
      return VrxChannel('$to.$channel', handles.first.toSocket());
    } finally {
      await socket.close();
    }
  }

  /// This applet's Listen: the intents it handles and the channels opened
  /// on it (the newest Listen of an applet wins), held again whenever
  /// vrxhost restarts.
  static Stream<VrxDelivery> listen() => resubscribed(_listenOnce);

  static Stream<VrxDelivery> _listenOnce() async* {
    final socket = await _connect('io.vrx.Host.Listen', const {}, more: true);
    try {
      await for (final (reply, handles) in _replies(socket)) {
        final d = deliveryOf(reply, () => handles.isEmpty ? null : handles.first.toSocket());
        if (d != null) yield d;
      }
    } finally {
      await socket.close();
    }
  }

  /// Answer an intent Listen asked about.
  static Future<void> answer(int id, {required bool handled}) =>
      VarlinkClient(socketPath).call('io.vrx.Host.Answer', {'id': id, 'verdict': handled ? 'handled' : 'pass'});
}
