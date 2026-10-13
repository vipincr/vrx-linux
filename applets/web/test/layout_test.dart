import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_check/vrx_check.dart';

import 'package:web_applet/main.dart';
import 'package:web_applet/state.dart';

/// The Web requests screens hold on every display vrx drives (vrx_check).
void main() {
  final history = ['https://example.com', 'http://10.10.10.1:8080/status', 'https://api.github.com/repos/vipincr/vrx-linux/commits?per_page=1'];
  for (final display in allDisplays) {
    testWidgets('web history on ${display.name}', (tester) async {
      await expectCleanLayout(tester, WebApplet(WebModel()..history = history), display: display);
    });
    testWidgets('web response on ${display.name}', (tester) async {
      final m = WebModel()
        ..history = history
        ..url = history[2]
        ..response = const WebResponse(
          status: 200,
          reason: 'OK',
          headers: [('content-type', 'application/json; charset=utf-8'), ('server', 'GitHub.com')],
          body: '[{"sha":"ed8d6bcae9d81968ad722fd29a83079994ff11df","commit":{"message":"layer: the applets build"}}]',
          millis: 412,
          truncated: false,
        );
      await expectCleanLayout(tester, WebApplet(m), display: display);
    });
    testWidgets('web address on ${display.name}', (tester) async {
      await expectCleanLayout(tester, WebApplet(WebModel()..editing = true), display: display);
    });
  }
}
