import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

/// The consumer's side of a buffer queue against a producer speaking the
/// wire (vrx_protocol::bufq): the buffers arrive once as handles with the
/// offer, then only indices move.
void main() {
  test('the offer brings the buffers; filled records and give-backs carry only indices', () async {
    final dir = Directory.systemTemp.createTempSync('vrx-bufq');
    final path = '${dir.path}/q';
    final server = await RawServerSocket.bind(InternetAddress(path, type: InternetAddressType.unix), 0);
    final producerSide = Completer<RawSocket>();
    server.listen(producerSide.complete);
    final consumerSocket = await RawSocket.connect(InternetAddress(path, type: InternetAddressType.unix), 0);
    final producer = await producerSide.future;

    // two "buffers": any descriptors will do for the wire
    final files = [for (var i = 0; i < 2; i++) File('${dir.path}/b$i')..writeAsBytesSync(List.filled(64, i))];
    final handles = [for (final f in files) ResourceHandle.fromFile(f.openSync())];
    producer.sendMessage([SocketControlMessage.fromHandles(handles)], utf8.encode('{"buffers":2,"size":64}\n'));
    final queue = await VrxBufferQueue.accept('cam.frames', consumerSocket);
    expect((queue.buffers.length, queue.size), (2, 64));

    final frames = StreamIterator(queue.filled);
    producer.write(utf8.encode('{"index":1,"bytes":64,"sequence":2}\n{"index":0,"bytes":32,"sequence":3}\n'));
    expect(await frames.moveNext(), isTrue);
    expect((frames.current.index, frames.current.bytes, frames.current.sequence), (1, 64, 2));
    expect(await frames.moveNext(), isTrue);
    expect(frames.current.index, 0);

    // the give-back is one short line on the stream, not the data
    final back = Completer<String>();
    producer.listen((e) {
      if (e == RawSocketEvent.read && !back.isCompleted) back.complete(utf8.decode(producer.read() ?? []));
    });
    queue.giveBack(1);
    expect(await back.future, '{"index":1}\n');

    await frames.cancel();
    await producer.close();
    await server.close();
    dir.deleteSync(recursive: true);
  }, skip: Platform.isLinux || Platform.isMacOS ? false : 'descriptor passing is Linux and macOS');
}
