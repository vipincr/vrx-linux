import 'package:vrx_kit/vrx_kit.dart';

/// Everything Web requests reacts to (plan 0013 D1: the reducer is the
/// only writer): a signal, or what happened, as data.
sealed class WebAction {
  const WebAction();

  static const init = WebSignal.init;
  static const back = WebSignal.back;
}

enum WebSignal implements WebAction { init, back }

/// The kept requests, read from their file.
final class WebHistory implements WebAction {
  const WebHistory(this.requests);

  final List<WebRequest> requests;
}

/// A new request opened: from one to change and send again, or empty.
final class WebCompose implements WebAction {
  const WebCompose([this.from]);

  final WebRequest? from;
}

/// The request being written changed; its field screen closes.
final class WebDraft implements WebAction {
  const WebDraft(this.draft);

  final WebRequest draft;
}

/// A field's screen opened (address, header, body).
final class WebEditField implements WebAction {
  const WebEditField(this.field);

  final WebField field;
}

/// A request went out; it heads the history.
final class WebSent implements WebAction {
  const WebSent(this.request);

  final WebRequest request;
}

/// The request ended: its response, or why there is none.
final class WebAnswered implements WebAction {
  const WebAnswered({this.response, this.error});

  final WebResponse? response;
  final String? error;
}

/// A request that was not sent, and why.
final class WebRefused implements WebAction {
  const WebRefused(this.error);

  final String error;
}

/// [history] with [r] at its top, once, at most [historyMax] long: what
/// the reducer keeps and what the file saves.
List<WebRequest> remembered(List<WebRequest> history, WebRequest r) =>
    [r, for (final h in history) if (h != r) h].take(historyMax).toList();

/// What is kept of a response body: enough to read on a panel.
const bodyLimit = 64 * 1024;

/// The requests kept to send again, whole (evrx-rt's rest applet: eight).
const historyMax = 8;

/// The methods offered, in the order a tap steps through them.
const methods = ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD'];

/// One request: what is sent, all of it, so it can be sent again.
class WebRequest {
  const WebRequest({this.method = 'GET', this.url = '', this.header = '', this.body = ''});

  /// A history entry: an object, or an address alone (kept before
  /// requests had more than an address), which is a GET.
  factory WebRequest.fromJson(Object? j) {
    if (j is String) return WebRequest(url: j);
    final m = (j as Map?) ?? const {};
    return WebRequest(
      method: methods.contains(m['method']) ? m['method'] as String : 'GET',
      url: '${m['url'] ?? ''}',
      header: '${m['header'] ?? ''}',
      body: '${m['body'] ?? ''}',
    );
  }

  final String method;
  final String url;

  /// One header, "Name: value", or ''.
  final String header;
  final String body;

  /// The method carries a body.
  bool get sendsBody => method == 'POST' || method == 'PUT' || method == 'PATCH';

  WebRequest copyWith({String? method, String? url, String? header, String? body}) =>
      WebRequest(method: method ?? this.method, url: url ?? this.url, header: header ?? this.header, body: body ?? this.body);

  /// The next method a tap gives.
  WebRequest nextMethod() => copyWith(method: methods[(methods.indexOf(method) + 1) % methods.length]);

  Map<String, String> toJson() => {
        'method': method,
        'url': url,
        if (header.isNotEmpty) 'header': header,
        if (sendsBody && body.isNotEmpty) 'body': body,
      };

  @override
  bool operator ==(Object other) =>
      other is WebRequest && other.method == method && other.url == url && other.header == header && (other.sendsBody ? other.body == body : true);

  @override
  int get hashCode => Object.hash(method, url, header, sendsBody ? body : '');
}

/// "Name: value" as a header, or null when it is not one.
(String, String)? parseHeader(String text) {
  final at = text.indexOf(':');
  if (at <= 0) return null;
  final name = text.substring(0, at).trim();
  if (name.isEmpty || name.contains(' ')) return null;
  return (name, text.substring(at + 1).trim());
}

class WebResponse {
  const WebResponse({required this.status, required this.reason, required this.headers, required this.body, required this.millis, required this.truncated});

  final int status;
  final String reason;
  final List<(String, String)> headers;
  final String body;
  final int millis;
  final bool truncated;
}

/// Which part of the request is being typed.
enum WebField { none, url, header, body }

class WebView {
  const WebView({
    required this.history,
    required this.editing,
    required this.draft,
    required this.field,
    required this.sent,
    required this.busy,
    required this.response,
    required this.error,
  });

  final List<WebRequest> history;

  /// The request screen is open.
  final bool editing;
  final WebRequest draft;
  final WebField field;

  /// The request sent, whose response is shown; null at the list.
  final WebRequest? sent;
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
  List<WebRequest> history = [];
  bool editing = false;
  WebRequest draft = const WebRequest();
  WebField field = WebField.none;
  WebRequest? sent;
  bool busy = false;
  WebResponse? response;
  String? error;


  @override
  WebState get initial => const WebState();

  @override
  WebAction get bootAction => WebAction.init;

  @override
  WebView reduce(WebState state, WebAction action) {
    switch (action) {
      case WebHistory(:final requests):
        history = requests.take(historyMax).toList();
      case WebCompose(:final from):
        draft = from ?? const WebRequest();
        editing = true;
        field = WebField.none;
      case WebDraft(draft: final d):
        draft = d;
        field = WebField.none;
      case WebEditField(field: final f):
        field = f;
      case WebSent(:final request):
        editing = false;
        field = WebField.none;
        sent = request;
        busy = true;
        response = null;
        error = null;
        history = remembered(history, request);
      case WebAnswered(response: final res, error: final err):
        busy = false;
        if (res != null) response = res;
        if (err != null) error = err;
      case WebRefused(error: final err):
        error = err;
      case WebSignal.back:
        if (field != WebField.none) {
          field = WebField.none;
        } else if (editing) {
          editing = false;
        } else {
          sent = null;
          response = null;
          error = null;
        }
      case WebSignal.init:
        break;
    }
    return WebView(
      history: List.unmodifiable(history),
      editing: editing,
      draft: draft,
      field: field,
      sent: sent,
      busy: busy,
      response: response,
      error: error,
    );
  }

  @override
  WebState get snapshot => const WebState();

  /// The history is its own file; the snapshot carries nothing.
  @override
  void restore(WebState snapshot) {}

  @override
  WebAction get backAction => WebAction.back;

  @override
  bool get atRoot => field == WebField.none && !editing && sent == null;

  @override
  Object? get fingerprint => [history, editing, draft, field, sent, busy, response?.status, response?.body, error];
}

class WebState {
  const WebState();
}
