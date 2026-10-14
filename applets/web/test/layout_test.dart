import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_check/vrx_check.dart';

import 'package:web_applet/main.dart';
import 'package:web_applet/state.dart';

/// The Web requests screens hold on every display vrx drives (vrx_check).
void main() {
  const history = [
    WebRequest(url: 'https://example.com'),
    WebRequest(method: 'POST', url: 'http://10.10.10.1:8080/status', header: 'Content-Type: application/json', body: '{"on": true}'),
    WebRequest(url: 'https://api.github.com/repos/vipincr/vrx-linux/commits?per_page=1'),
  ];
  final cases = <String, WebModel Function()>{
    'history': () => WebModel()..history = [...history],
    'request': () => WebModel()..reduce(const WebState(), WebCompose(history[1])),
    'address': () => WebModel()
      ..reduce(const WebState(), WebCompose(history[1]))
      ..field = WebField.url,
    'waiting': () => WebModel()
      ..sent = history[2]
      ..busy = true,
    'response': () => WebModel()
      ..history = [...history]
      ..sent = history[2]
      ..response = const WebResponse(
        status: 200,
        reason: 'OK',
        headers: [('content-type', 'application/json; charset=utf-8'), ('server', 'GitHub.com')],
        body: '[{"sha":"ed8d6bcae9d81968ad722fd29a83079994ff11df","commit":{"message":"layer: the applets build"}}]',
        millis: 412,
        truncated: false,
      ),
  };
  for (final display in allDisplays) {
    for (final c in cases.entries) {
      testWidgets('web ${c.key} on ${display.name}', (tester) async {
        await expectCleanLayout(tester, WebApplet(c.value()), display: display);
      });
    }
  }
}
