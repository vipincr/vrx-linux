import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' hide Intent;
import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

/// A stand-in vrxhost: answers each one-line request with `answer`,
/// recording what it was asked.
Future<(ServerSocket, List<Map<String, dynamic>>, String)> fakeHost(
    Map<String, dynamic> Function(Map<String, dynamic>) answer) async {
  final dir = await Directory.systemTemp.createTemp('vrxhost');
  final path = '${dir.path}/vrx.sock';
  final server = await ServerSocket.bind(InternetAddress(path, type: InternetAddressType.unix), 0);
  final asked = <Map<String, dynamic>>[];
  server.listen((client) async {
    final line = await utf8.decoder.bind(client).transform(const LineSplitter()).first;
    final request = jsonDecode(line) as Map<String, dynamic>;
    asked.add(request);
    client.write('${jsonEncode(answer(request))}\n');
    await client.flush();
    await client.close();
  });
  return (server, asked, path);
}

void main() {
  test('a nav push asks vrxhost by name and the answer maps to a verdict', () async {
    final (server, asked, path) = await fakeHost(
        (r) => {'ok': true, 'verdict': 'opened', 'handled_by': r['payload']['applet']});
    final host = VrxHost(socketPath: path);
    final result = await host.send('vrx.nav.push', {'applet': 'clock'});
    expect(result.verdict, Verdict.handled);
    expect(result.handledBy, 'clock');
    expect(asked.single, {'name': 'vrx.nav.push', 'payload': {'applet': 'clock'}});
    await server.close();
  });

  test('the registry list becomes tiles; a refusal keeps its errno', () async {
    final (server, _, path) = await fakeHost((r) => r['name'] == 'vrx.registry.list'
        ? {
            'ok': true,
            'applets': [
              {'id': 'clock', 'name': 'Clock', 'icon': 'clock.png', 'position': 3},
            ],
          }
        : {'ok': false, 'errno': -2, 'error': 'no applet "ghost"'});
    final host = VrxHost(socketPath: path);
    final applets = await host.applets();
    expect(applets.single.id, 'clock');
    expect(applets.single.position, 3);
    final refused = await host.send('vrx.nav.push', {'applet': 'ghost'});
    expect(refused.verdict, Verdict.error);
    expect(refused.errno, -2);
    await server.close();
  });

  test('no socket: nothing is installed, and a send says why it failed', () async {
    expect(VrxHost.installIfPresent(socketPath: '/nonexistent/vrx.sock'), isNull);
    final result = await VrxHost(socketPath: '/nonexistent/vrx.sock').send('a.b', null);
    expect(result.verdict, Verdict.error);
    expect(result.error, isNotNull);
  });

  testWidgets('the applet host renders the view and the view dispatches', (tester) async {
    await tester.pumpWidget(AppletHost(applet: _Counter()));
    expect(find.text('0'), findsOneWidget);
    await tester.tap(find.byType(GestureDetector));
    await tester.pump();
    expect(find.text('1'), findsOneWidget);
  });
}

class _Counter extends Applet<int, String, int> {
  int _n = 0;

  @override
  int get initial => 0;

  @override
  String get bootAction => 'init';

  @override
  int reduce(int state, String action) => action == 'add' ? ++_n : _n;

  @override
  int get snapshot => _n;

  @override
  Widget build(BuildContext context, int view) => GestureDetector(
        onTap: () => AppletScope.dispatch<String>(context, 'add'),
        child: Text('$view'),
      );
}
