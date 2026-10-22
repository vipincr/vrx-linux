/// The inter-applet bridge from an applet (plan 0008 D15), over vrxhost's
/// io.vrx.Host: channels (streams between two applets, ordered JSON
/// records, one per line) and Listen (the intents this applet handles and
/// the channels others open on it). The streams ride as file descriptors
/// on the Varlink socket, which dart:io's RawSocket messages carry.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';

import 'host.dart';

/// A stream between two applets that vrxhost opened.
///
/// The stream rides a descriptor over the varlink socket, and the
/// descriptor is held as a [RawSocket] written to synchronously. It
/// cannot be a [Socket]: `ResourceHandle.toSocket()` hands back a Socket
/// whose buffered writes never flush — an applet's request sat in it
/// with no write syscall at all, while the buffer queue's
/// [ResourceHandle.toRawSocket] wrote beside it at 30 fps (bench
/// 2026-10-22, disp28a: the camera applet's captures never reached
/// camerad, three times, root callers with the same channel worked). A
/// partial write waits for writable and finishes.
class VrxChannel {
  VrxChannel(this.name, this.socket);

  /// `<applet>.<channel>`.
  final String name;
  final RawSocket socket;

  final _out = <int>[];
  final _records = StreamController<Object?>();
  final _in = <int>[];

  /// Reads from the socket as they come, records out as they parse; a
  /// channel nobody listens to buffers, so a channel is listened by
  /// design (its opener wants the replies).
  late final StreamSubscription<RawSocketEvent> _events =
      socket.listen(_on, onError: (Object e) {
    _records.addError(e);
  }, onDone: _ended);

  /// Write one JSON record. The write leaves this isolate now; what the
  /// peer does with it is the [records] side's story.
  void write(Object? record) {
    _out.addAll(
        utf8.encode('${jsonEncode({'pipe': name, 'record': record})}\n'));
    _flush();
  }

  /// The records the other end writes, until it closes.
  Stream<Object?> get records {
    _events;
    return _records.stream;
  }

  /// Let the channel go: the descriptor closes, [records] ends.
  void close() {
    _ended();
    unawaited(socket.close());
  }

  void _flush() {
    _events;
    if (_out.isEmpty) return;
    final waiting = Uint8List.fromList(_out);
    _out.clear();
    var done = 0;
    try {
      done = socket.write(waiting);
    } on Object {
      // a dead channel says so through records ending; a late write is
      // nobody's crash
      return;
    }
    if (done < waiting.length) {
      _out.insertAll(0, waiting.sublist(done));
    }
  }

  void _on(RawSocketEvent event) {
    switch (event) {
      case RawSocketEvent.read:
        // readMessage, not read: it is what the buffer queue and the
        // varlink bridge read with (and the bench Mac's Dart returns
        // read()'s bytes mangled — 2026-10-22, a dart-VM echo probe)
        final message = socket.readMessage();
        if (message == null || message.data.isEmpty) return;
        _in.addAll(message.data);
        while (true) {
          final end = _in.indexOf(10);
          if (end < 0) return;
          final line = utf8.decode(_in.sublist(0, end));
          _in.removeRange(0, end + 1);
          if (line.isNotEmpty) {
            _records.add((jsonDecode(line) as Map<String, dynamic>)['record']);
          }
        }
      case RawSocketEvent.write:
        _flush();
      case RawSocketEvent.readClosed || RawSocketEvent.closed:
        _ended();
      default:
        break;
    }
  }

  void _ended() {
    if (!_records.isClosed) unawaited(_records.close());
    unawaited(_events.cancel());
  }
}

/// What vrxhost hands a listening applet.
sealed class VrxDelivery {
  const VrxDelivery();
}

/// An intent this applet handles; with an [id], [VrxBridge.answer] it
/// within 100 ms (silence is a pass).
class VrxIntentDelivery extends VrxDelivery {
  const VrxIntentDelivery(
      {required this.id, required this.name, required this.payload});

  final int? id;
  final String name;
  final Object? payload;
}

/// This applet was opened at [route] ('' is the root), with the payload
/// of the intent that opened it there, if one did (plan 0011 D5).
class VrxRouteDelivery extends VrxDelivery {
  const VrxRouteDelivery({required this.route, this.payload, this.intent});

  final String route;
  final Object? payload;

  /// The intent that opened it there, or null for a plain push.
  final String? intent;
}

/// Another applet opened one of this applet's channels: the stream's end,
/// to read as records ([asChannel]) or as a buffer queue ([asBufferQueue]),
/// whichever the channel carries (the manifests agree on it).
class VrxChannelDelivery extends VrxDelivery {
  const VrxChannelDelivery(
      {required this.from, required this.name, required this.handle});

  final String from;

  /// `<from>.<channel>`.
  final String name;
  final ResourceHandle handle;

  VrxChannel asChannel() => VrxChannel(name, handle.toRawSocket());

  Future<VrxBufferQueue> asBufferQueue() =>
      VrxBufferQueue.accept(name, handle.toRawSocket());
}

/// A filled buffer: which one, how many bytes, and its frame number (a gap
/// is a frame the producer dropped for want of a free buffer).
class VrxBufferFilled {
  const VrxBufferFilled(this.index, this.bytes, this.sequence);

  final int index;
  final int bytes;
  final int sequence;
}

/// The consumer's side of a buffer queue (plan 0009 D10; the wire is
/// vrx_protocol::bufq): the buffers arrived once, as handles with the
/// producer's offer; after that only indices move. Hand a buffer's handle to
/// whatever reads it, and give the index back when done.
class VrxBufferQueue {
  VrxBufferQueue._(
      this.name, this._socket, this.buffers, this.size, this._filled);

  final String name;
  final RawSocket _socket;

  /// The buffers' handles (memfds or dmabufs), by index.
  final List<ResourceHandle> buffers;

  /// Each buffer's size in bytes.
  final int size;
  final Stream<VrxBufferFilled> _filled;

  /// Filled buffers as the producer queues them, until it closes.
  Stream<VrxBufferFilled> get filled => _filled;

  static Future<VrxBufferQueue> accept(String name, RawSocket socket) async {
    final frames = StreamController<VrxBufferFilled>();
    final offer = Completer<(int, int, List<ResourceHandle>)>();
    final handles = <ResourceHandle>[];
    final pending = <int>[];
    late StreamSubscription<RawSocketEvent> sub;
    sub = socket.listen((event) {
      if (event == RawSocketEvent.readClosed ||
          event == RawSocketEvent.closed) {
        if (!offer.isCompleted)
          offer.completeError(StateError('$name: closed before its offer'));
        unawaited(frames.close());
        unawaited(sub.cancel());
        return;
      }
      if (event != RawSocketEvent.read) return;
      final message = socket.readMessage();
      if (message == null) return;
      for (final control in message.controlMessages) {
        handles.addAll(control.extractHandles());
      }
      pending.addAll(message.data);
      while (true) {
        final end = pending.indexOf(10);
        if (end < 0) break;
        // CON-03 (review 2026-10-17): a malformed offer (bad JSON, wrong
        // shape) completes the accept with an error — throwing inside the
        // socket callback killed the listener and offer.future never
        // completed, so VrxBufferQueue.accept hung for ever
        Map<String, dynamic> line;
        try {
          line = jsonDecode(utf8.decode(pending.sublist(0, end)))
              as Map<String, dynamic>;
        } on Object catch (err) {
          pending.removeRange(0, end + 1);
          if (!offer.isCompleted) {
            offer.completeError(StateError('$name: a malformed offer: $err'));
          }
          continue;
        }
        pending.removeRange(0, end + 1);
        if (!offer.isCompleted) {
          if (line['buffers'] is! num || line['size'] is! num) {
            offer.completeError(
                StateError('$name: the offer names no buffer count or size'));
            continue;
          }
          offer.complete((
            (line['buffers'] as num).toInt(),
            (line['size'] as num).toInt(),
            List.of(handles)
          ));
        } else {
          frames.add(VrxBufferFilled(
              (line['index'] as num).toInt(),
              (line['bytes'] as num).toInt(),
              (line['sequence'] as num).toInt()));
        }
      }
    });
    final (count, size, got) = await offer.future;
    if (got.length != count)
      throw StateError(
          '$name: the offer names $count buffers, ${got.length} came with it');
    return VrxBufferQueue._(name, socket, got, size, frames.stream);
  }

  /// Buffer [index] is free again.
  void giveBack(int index) =>
      _socket.write(utf8.encode('${jsonEncode({'index': index})}\n'));
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
VrxDelivery? deliveryOf(
    Map<String, dynamic> reply, ResourceHandle? Function() stream) {
  final p = (reply['parameters'] as Map<String, dynamic>?) ?? const {};
  switch (p['kind']) {
    case 'intent':
      return VrxIntentDelivery(
          id: (p['id'] as num?)?.toInt(),
          name: p['name'] as String? ?? '',
          payload: p['payload']);
    case 'route':
      return VrxRouteDelivery(
          route: p['route'] as String? ?? '',
          payload: p['payload'],
          intent: p['name'] as String?);
    case 'channel':
      final handle = stream();
      if (handle == null) return null;
      final from = p['from'] as String? ?? '';
      return VrxChannelDelivery(
          from: from, name: '$from.${p['channel'] ?? ''}', handle: handle);
  }
  return null;
}

/// io.vrx.Host's bridge calls.
abstract final class VrxBridge {
  static String socketPath = VarlinkAppletsService.defaultSocket;

  static Future<RawSocket> _connect(
      String method, Map<String, dynamic> parameters,
      {bool more = false}) async {
    final socket = await RawSocket.connect(
        InternetAddress(socketPath, type: InternetAddressType.unix), 0);
    final call = {
      'method': method,
      'parameters': parameters,
      if (more) 'more': true
    };
    socket.write([...utf8.encode(jsonEncode(call)), 0]);
    return socket;
  }

  /// Every reply on [socket], each with the descriptors that came with it.
  static Stream<(Map<String, dynamic>, List<ResourceHandle>)> _replies(
      RawSocket socket) async* {
    final frames = VarlinkFrames();
    final handles = <ResourceHandle>[];
    await for (final event in socket) {
      if (event == RawSocketEvent.closed || event == RawSocketEvent.readClosed)
        return;
      if (event != RawSocketEvent.read) continue;
      final message = socket.readMessage();
      if (message == null) continue;
      for (final control in message.controlMessages) {
        handles.addAll(control.extractHandles());
      }
      for (final reply in frames.add(message.data)) {
        final error = reply['error'];
        if (error is String) {
          throw VarlinkError(error,
              (reply['parameters'] as Map<String, dynamic>?) ?? const {});
        }
        final p = (reply['parameters'] as Map<String, dynamic>?) ?? const {};
        // a channel delivery or an Open reply carries the stream's end
        final carries = p['kind'] == 'channel' || !p.containsKey('kind');
        yield (
          reply,
          carries && handles.isNotEmpty
              ? [handles.removeAt(0)]
              : const <ResourceHandle>[]
        );
        if (reply['continues'] != true) return;
      }
    }
  }

  /// Open `<to>.<channel>`: it must be in this applet's channels.opens
  /// and the other applet's channels.offers, and that applet listening.
  static Future<VrxChannel> open(String to, String channel) async {
    final socket =
        await _connect('io.vrx.Host.Open', {'to': to, 'channel': channel});
    try {
      final (_, handles) = await _replies(socket).first;
      if (handles.isEmpty)
        throw const VarlinkError('io.vrx.Host.Unavailable', {});
      return VrxChannel('$to.$channel', handles.first.toRawSocket());
    } finally {
      await socket.close();
    }
  }

  /// This applet's Listen: the intents it handles, the routes it is opened
  /// at while running, and the channels opened on it, held again whenever
  /// vrxhost restarts. The newest Listen of an applet wins, so there is one
  /// per process, shared by every listener here.
  static Stream<VrxDelivery> listen() =>
      _listen ??= resubscribed(_listenOnce).asBroadcastStream();

  static Stream<VrxDelivery>? _listen;

  static Stream<VrxDelivery> _listenOnce() async* {
    final socket = await _connect('io.vrx.Host.Listen', const {}, more: true);
    try {
      await for (final (reply, handles) in _replies(socket)) {
        final d =
            deliveryOf(reply, () => handles.isEmpty ? null : handles.first);
        if (d != null) yield d;
      }
    } finally {
      await socket.close();
    }
  }

  /// Answer an intent Listen asked about.
  static Future<void> answer(int id, {required bool handled}) =>
      VarlinkClient(socketPath).call('io.vrx.Host.Answer',
          {'id': id, 'verdict': handled ? 'handled' : 'pass'});
}
