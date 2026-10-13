import 'package:vrx_kit/vrx_kit.dart';

enum WebAction { init, editing, sent, answered, failed, back, historyLoaded }

/// What is kept of a response body: enough to read on a panel.
const bodyLimit = 64 * 1024;
const historyMax = 20;

class WebResponse {
  const WebResponse({required this.status, required this.reason, required this.headers, required this.body, required this.millis, required this.truncated});

  final int status;
  final String reason;
  final List<(String, String)> headers;
  final String body;
  final int millis;
  final bool truncated;
}

class WebView {
  const WebView({required this.history, required this.editing, required this.url, required this.busy, required this.response, required this.error});

  final List<String> history;
  final bool editing;
  final String? url;
  final bool busy;
  final WebResponse? response;
  final String? error;
}

/// A URL as typed: a scheme added when there is none.
String normaliseUrl(String typed) {
  final t = typed.trim();
  if (t.isEmpty) return t;
  return t.contains('://') ? t : 'https://$t';
}

/// A URL as two lines a person reads: the host, then the rest.
(String, String) splitUrl(String url) {
  final u = Uri.tryParse(url);
  if (u == null || u.host.isEmpty) return (url, '');
  final host = u.hasPort ? '${u.host}:${u.port}' : u.host;
  final rest = '${u.path.isEmpty ? '/' : u.path}${u.hasQuery ? '?${u.query}' : ''}';
  return (u.scheme == 'https' ? host : '${u.scheme}://$host', rest == '/' ? '' : rest);
}

class WebModel extends StoreModel<WebState, WebAction, WebView> {
  List<String> history = [];
  bool editing = false;
  String? url;
  bool busy = false;
  WebResponse? response;
  String? error;

  /// Remember [u] at the top of the history, once.
  void remember(String u) {
    history
      ..remove(u)
      ..insert(0, u);
    if (history.length > historyMax) history.removeRange(historyMax, history.length);
  }

  @override
  WebState get initial => const WebState();

  @override
  WebAction get bootAction => WebAction.init;

  @override
  WebView reduce(WebState state, WebAction action) {
    if (action == WebAction.back) {
      if (editing) {
        editing = false;
      } else {
        url = null;
        response = null;
        error = null;
      }
    }
    return WebView(history: List.unmodifiable(history), editing: editing, url: url, busy: busy, response: response, error: error);
  }

  @override
  WebState get snapshot => const WebState();
}

class WebState {
  const WebState();
}
