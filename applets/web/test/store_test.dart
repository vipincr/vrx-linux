import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

import 'package:web_applet/state.dart';

void main() {
  test('a typed address gets a scheme; history keeps twenty, newest first, once each', () {
    expect(normaliseUrl(' example.com '), 'https://example.com');
    expect(normaliseUrl('http://10.10.10.1:8080/x'), 'http://10.10.10.1:8080/x');
    expect(splitUrl('https://example.com/'), ('example.com', ''));
    expect(splitUrl('http://10.10.10.1:8080/s?a=1'), ('http://10.10.10.1:8080', '/s?a=1'));
    final m = WebModel();
    for (var i = 0; i < 25; i++) {
      m.remember('https://h$i');
    }
    m.remember('https://h10');
    expect(m.history.length, historyMax);
    expect(m.history.first, 'https://h10');
    expect(m.history.where((u) => u == 'https://h10').length, 1);
  });

  test('back leaves the editor, then the response', () {
    final m = WebModel()
      ..url = 'https://example.com'
      ..editing = true;
    final h = StoreHarness(m);
    h.dispatch(WebAction.back);
    h.assertView((v) => !v.editing && v.url != null);
    h.dispatch(WebAction.back);
    h.assertView((v) => v.url == null);
  });
}
