import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' hide Intent; // vrx's Intent
import 'package:vrx_kit/vrx_kit.dart';

import 'state.dart';

final _events = StreamController<WebAction>();

String get _historyPath => '${Platform.environment['HOME'] ?? '/var/lib/vrx/web'}/history.json';

/// Web requests: a request (method, address, one header, a body) and
/// its response: status, headers, body. The last eight requests are kept
/// whole, to send again or change.
class WebApplet extends Applet<WebState, WebAction, WebView> {
  WebApplet(this.model);

  final WebModel model;
  HttpClient? _client;

  @override
  WebState get initial => model.initial;

  @override
  WebAction get bootAction => model.bootAction;

  @override
  WebView reduce(WebState state, WebAction action) => model.reduce(state, action);

  @override
  WebState get snapshot => model.snapshot;

  Future<void> send(WebRequest typed) async {
    final r = typed.copyWith(url: normaliseUrl(typed.url));
    if (r.url.isEmpty || _client != null) return;
    final header = r.header.isEmpty ? null : parseHeader(r.header);
    if (r.header.isNotEmpty && header == null) {
      model.error = 'The header is written "Name: value".';
      _events.add(WebAction.failed);
      return;
    }
    model
      ..editing = false
      ..field = WebField.none
      ..sent = r
      ..busy = true
      ..response = null
      ..error = null
      ..remember(r);
    _events.add(WebAction.sent);
    unawaited(_saveHistory());
    final client = _client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    final watch = Stopwatch()..start();
    try {
      final req = await client.openUrl(r.method, Uri.parse(r.url));
      req.headers.set(HttpHeaders.userAgentHeader, 'vrx-web/1.0');
      if (header != null) req.headers.set(header.$1, header.$2);
      if (r.sendsBody && r.body.isNotEmpty) req.add(utf8.encode(r.body));
      final res = await req.close().timeout(const Duration(seconds: 20));
      final bytes = <int>[];
      var truncated = false;
      await for (final chunk in res) {
        bytes.addAll(chunk);
        if (bytes.length >= bodyLimit) {
          truncated = true;
          break;
        }
      }
      final headers = <(String, String)>[];
      res.headers.forEach((k, v) => headers.add((k, v.join(', '))));
      headers.sort((a, b) => a.$1.compareTo(b.$1));
      model.response = WebResponse(
        status: res.statusCode,
        reason: res.reasonPhrase,
        headers: headers,
        body: utf8.decode(bytes.length > bodyLimit ? bytes.sublist(0, bodyLimit) : bytes, allowMalformed: true),
        millis: watch.elapsedMilliseconds,
        truncated: truncated,
      );
      _events.add(WebAction.answered);
    } on Object catch (err) {
      // a Stop closes the client under the request: that is no failure
      model.error = _client == null ? 'Stopped.' : VrxWords.of(err, context: 'web');
      _events.add(WebAction.failed);
    } finally {
      model.busy = false;
      _client = null;
      client.close(force: true);
      _events.add(WebAction.answered);
    }
  }

  void stop() {
    final c = _client;
    _client = null;
    c?.close(force: true);
  }

  Future<void> _saveHistory() async {
    try {
      await VrxFile.writeAtomic(_historyPath, jsonEncode([for (final r in model.history) r.toJson()]));
    } on Object catch (err) {
      debugPrint('web: cannot save history: $err');
    }
  }

  void _change(void Function() change) {
    change();
    _events.add(WebAction.editing);
  }

  @override
  Widget build(BuildContext context, WebView view) {
    final Widget body;
    final d = view.draft;
    if (view.editing && view.field != WebField.none) {
      final (title, initial, hint) = switch (view.field) {
        WebField.url => ('Address', d.url, 'example.com'),
        WebField.header => ('Header', d.header, 'Accept: application/json'),
        _ => ('Body', d.body, '{"key": "value"}'),
      };
      body = VrxTextEntry(
        key: ValueKey(view.field),
        title: title,
        initial: initial,
        hint: hint,
        onBack: () => _events.add(WebAction.back),
        onDone: (t) => _change(() {
          model.draft = switch (view.field) {
            WebField.url => d.copyWith(url: t.trim()),
            WebField.header => d.copyWith(header: t.trim()),
            _ => d.copyWith(body: t),
          };
          model.field = WebField.none;
        }),
      );
    } else if (view.editing) {
      body = VrxList(children: [
        VrxHeader(title: 'Request', onBack: () => _events.add(WebAction.back)),
        VrxRow(label: 'Method', value: d.method, onTap: () => _change(() => model.draft = d.nextMethod())),
        VrxRow(label: 'Address', value: d.url.isEmpty ? 'None yet' : d.url, onTap: () => _change(() => model.field = WebField.url)),
        VrxRow(label: 'Header', value: d.header.isEmpty ? 'None' : d.header, onTap: () => _change(() => model.field = WebField.header)),
        if (d.sendsBody)
          VrxRow(label: 'Body', value: d.body.isEmpty ? 'Empty' : d.body, onTap: () => _change(() => model.field = WebField.body)),
        VrxRow(glyph: VrxSymbols.send, label: 'Send', onTap: d.url.trim().isEmpty ? null : () => unawaited(send(d))),
      ]);
    } else if (view.sent != null) {
      body = _Result(
        view: view,
        onBack: () => _events.add(WebAction.back),
        onAgain: () => unawaited(send(view.sent!)),
        onStop: stop,
        onChange: () => _change(() => model.compose(view.sent)),
      );
    } else {
      body = VrxList(children: [
        const VrxHeader(title: 'Web requests', onBack: Nav.pop),
        VrxRow(glyph: VrxSymbols.add, label: 'New request', onTap: () => _change(model.compose)),
        // a tap sends it again; its hold opens it to change first
        for (final r in view.history)
          VrxRow(
            label: splitUrl(r.url).$1,
            detail: '${r.method} ${splitUrl(r.url).$2.isEmpty ? '/' : splitUrl(r.url).$2}${r.header.isEmpty ? '' : ' · ${r.header}'}',
            onTap: () => unawaited(send(r)),
            onLongPress: () => _change(() => model.compose(r)),
          ),
        if (view.history.isNotEmpty) const _Note('Press and hold a request to change it before sending.'),
      ]);
    }
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          Expanded(child: body),
          if (view.error != null && view.sent == null) VrxBanner(text: view.error),
        ]),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final space = ScaledSpacing.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: space.inset, vertical: space.sm),
      child: Text(text, style: TypeRole.caption(context)),
    );
  }
}

class _Result extends StatelessWidget {
  const _Result({required this.view, required this.onBack, required this.onAgain, required this.onStop, required this.onChange});

  final WebView view;
  final VoidCallback onBack, onAgain, onStop, onChange;

  @override
  Widget build(BuildContext context) {
    final space = ScaledSpacing.of(context);
    final r = view.response;
    final sent = view.sent!;
    final mono = TypeRole.caption(context).copyWith(fontFamily: 'Liberation Mono');
    return Column(children: [
      VrxHeader(title: 'Response', onBack: onBack, action: view.busy ? null : VrxChip(label: 'Change', onTap: onChange)),
      if (view.busy)
        VrxRow(glyph: VrxSymbols.stop, label: 'Waiting for the answer', value: 'Stop', onTap: onStop)
      else
        VrxRow(
          label: r == null ? (view.error ?? '') : '${r.status} ${r.reason} · ${r.millis} ms',
          value: 'Send again',
          onTap: onAgain,
        ),
      // the whole request, the address wrapping at its punctuation
      Padding(
        padding: EdgeInsets.symmetric(horizontal: space.inset, vertical: space.xs),
        child: Text(vrxBreakable('${sent.method} ${sent.url}'), style: TypeRole.caption(context)),
      ),
      Expanded(
        child: r == null
            ? const SizedBox.shrink()
            : ListView(padding: EdgeInsets.all(space.sm), children: [
                for (final (k, v) in r.headers) Text('$k: $v', style: mono),
                SizedBox(height: space.sm),
                SelectableText(r.body, style: mono),
                if (r.truncated) Text('Only the first ${bodyLimit ~/ 1024} KB are shown.', style: TypeRole.caption(context)),
              ]),
      ),
    ]);
  }
}

Future<void> main() async {
  final model = WebModel();
  runApplet(WebApplet(model), actions: _events.stream);
  try {
    final f = File(_historyPath);
    if (await f.exists()) {
      model.history = [for (final r in jsonDecode(await f.readAsString()) as List) WebRequest.fromJson(r)].take(historyMax).toList();
    }
  } on Object catch (err) {
    debugPrint('web: history unreadable: $err');
  }
  _events.add(WebAction.historyLoaded);
}
