import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

import 'package:web_applet/state.dart';

void main() {
  test('a typed address gets a scheme, and reads as host then path', () {
    expect(normaliseUrl(' example.com '), 'https://example.com');
    expect(normaliseUrl('http://10.10.10.1:8080/x'), 'http://10.10.10.1:8080/x');
    expect(splitUrl('https://example.com/'), ('example.com', ''));
    expect(splitUrl('http://10.10.10.1:8080/s?a=1'), ('http://10.10.10.1:8080', '/s?a=1'));
  });

  // plan 0011 Part D: the last eight requests, kept whole
  test('history keeps eight whole requests, newest first, once each', () {
    final m = WebModel();
    for (var i = 0; i < 12; i++) {
      m.remember(WebRequest(url: 'https://h$i'));
    }
    const post = WebRequest(method: 'POST', url: 'https://h10', header: 'Accept: application/json', body: '{}');
    m
      ..remember(post)
      ..remember(const WebRequest(url: 'https://h10'));
    expect(m.history.length, historyMax);
    expect(m.history.first, const WebRequest(url: 'https://h10'));
    expect(m.history[1], post, reason: 'a POST to the same address is another request');
    expect(m.history.where((r) => r == post).length, 1);
  });

  test('a request round-trips; an old address-only entry is a GET', () {
    const r = WebRequest(method: 'PUT', url: 'https://x', header: 'X-Key: 1', body: 'b');
    expect(WebRequest.fromJson(r.toJson()), r);
    expect(WebRequest.fromJson('https://old'), const WebRequest(url: 'https://old'));
    expect(const WebRequest(method: 'GET', body: 'ignored').toJson().containsKey('body'), isFalse);
    expect(const WebRequest().nextMethod().method, 'POST');
    expect(const WebRequest(method: 'HEAD').nextMethod().method, 'GET');
  });

  test('a header is "Name: value"', () {
    expect(parseHeader('Accept: application/json'), ('Accept', 'application/json'));
    expect(parseHeader('no colon'), isNull);
    expect(parseHeader('Bad name: x'), isNull);
  });

  test('back leaves the field, then the request screen, then the response', () {
    final m = WebModel()
      ..sent = const WebRequest(url: 'https://example.com')
      ..compose()
      ..field = WebField.url;
    final h = StoreHarness(m);
    h.dispatch(WebAction.back);
    h.assertView((v) => v.editing && v.field == WebField.none);
    h.dispatch(WebAction.back);
    h.assertView((v) => !v.editing && v.sent != null);
    h.dispatch(WebAction.back);
    h.assertView((v) => v.sent == null);
  });
}
