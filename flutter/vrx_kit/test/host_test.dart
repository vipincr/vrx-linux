import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' hide Intent;
import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

/// A stand-in io.vrx.Host: answers each NUL-terminated Varlink call with
/// `answer` (a list of replies; all but the last continue), recording
/// what it was asked.
Future<(ServerSocket, List<Map<String, dynamic>>, String)> fakeHost(
    List<Map<String, dynamic>> Function(Map<String, dynamic>) answer) async {
  final dir = await Directory.systemTemp.createTemp('vrxhost');
  final path = '${dir.path}/io.vrx.Host';
  final server = await ServerSocket.bind(InternetAddress(path, type: InternetAddressType.unix), 0);
  final asked = <Map<String, dynamic>>[];
  server.listen((client) async {
    final pending = <int>[];
    await for (final chunk in client) {
      for (final byte in chunk) {
        if (byte != 0) {
          pending.add(byte);
          continue;
        }
        final call = jsonDecode(utf8.decode(pending)) as Map<String, dynamic>;
        pending.clear();
        asked.add(call);
        final replies = answer(call);
        for (var i = 0; i < replies.length; i++) {
          final reply = {...replies[i], if (i < replies.length - 1) 'continues': true};
          client.add([...utf8.encode(jsonEncode(reply)), 0]);
        }
        await client.flush();
      }
    }
  });
  return (server, asked, path);
}

void main() {
  test('a nav push is an io.vrx.Host call by name', () async {
    final (server, asked, path) = await fakeHost((c) => [
          {'parameters': {'top': c['parameters']['applet']}}
        ]);
    final host = VarlinkAppletsService(socketPath: path);
    final result = await host.send('sys.alarm.ring', {'id': 7});
    expect(result.verdict, Verdict.handled);
    expect(asked.single['method'], 'io.vrx.Host.Intent');
    expect(asked.single['parameters'], {'name': 'sys.alarm.ring', 'payload': {'id': 7}});
    await server.close();
  });

  test('applets become tiles; a varlink error keeps its name', () async {
    final (server, _, path) = await fakeHost((c) => c['method'] == 'io.vrx.Host.Applets'
        ? [
            {
              'parameters': {
                'applets': [
                  {'id': 'clock', 'name': 'Clock', 'icon': 'schedule', 'position': 3},
                ],
              },
            }
          ]
        : [
            {'error': 'io.vrx.Host.NoHandler', 'parameters': {'name': 'ghost.ping'}}
          ]);
    final host = VarlinkAppletsService(socketPath: path);
    final applets = await host.applets();
    expect(applets.single.id, 'clock');
    expect(applets.single.icon, 'schedule');
    final refused = await host.send('ghost.ping', null);
    expect(refused.verdict, Verdict.error);
    expect(refused.error, 'io.vrx.Host.NoHandler');
    await server.close();
  });

  test('watch streams the front applet while the host continues', () async {
    final (server, asked, path) = await fakeHost((c) => [
          {'parameters': {'front': 'launcher', 'depth': 1}},
          {'parameters': {'front': 'clock', 'depth': 2}},
        ]);
    // the watch never ends: a host that hangs up is asked again
    final fronts = await VarlinkAppletsService(socketPath: path).watch().take(2).toList();
    expect(fronts.map((f) => f.front), ['launcher', 'clock']);
    expect(asked.first['more'], true);
    await server.close();
  });

  test('no socket: nothing is installed', () {
    expect(VarlinkAppletsService.ifPresent(socketPath: '/nonexistent/io.vrx.Host'), isNull);
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
