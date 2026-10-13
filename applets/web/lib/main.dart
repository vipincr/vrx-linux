import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' hide Intent; // vrx's Intent
import 'package:vrx_kit/vrx_kit.dart';

import 'state.dart';

final _events = StreamController<WebAction>();

String get _historyPath => '${Platform.environment['HOME'] ?? '/var/lib/vrx/web'}/history.json';

/// Web requests: a GET to a URL, its status, headers and body.
class WebApplet extends Applet<WebState, WebAction, WebView> {
  WebApplet(this.model);

  final WebModel model;

  @override
  WebState get initial => model.initial;

  @override
  WebAction get bootAction => model.bootAction;

  @override
  WebView reduce(WebState state, WebAction action) => model.reduce(state, action);

  @override
  WebState get snapshot => model.snapshot;

  Future<void> fetch(String typed) async {
    final u = normaliseUrl(typed);
    if (u.isEmpty) return;
    model
      ..editing = false
      ..url = u
      ..busy = true
      ..response = null
      ..error = null
      ..remember(u);
    _events.add(WebAction.sent);
    unawaited(_saveHistory());
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    final watch = Stopwatch()..start();
    try {
      final req = await client.getUrl(Uri.parse(u));
      req.headers.set(HttpHeaders.userAgentHeader, 'vrx-web/1.0');
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
      model.error = err is SocketException ? 'Cannot reach it: ${err.message}' : '$err';
      _events.add(WebAction.failed);
    } finally {
      model.busy = false;
      client.close(force: true);
      _events.add(WebAction.answered);
    }
  }

  Future<void> _saveHistory() async {
    try {
      final f = File(_historyPath);
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode(model.history));
    } on Object catch (err) {
      debugPrint('web: cannot save history: $err');
    }
  }

  void _edit() {
    model.editing = true;
    _events.add(WebAction.editing);
  }

  @override
  Widget build(BuildContext context, WebView view) {
    final Widget body;
    if (view.editing) {
      body = VrxTextEntry(
        title: 'Address',
        initial: view.url ?? '',
        hint: 'example.com',
        onBack: () => _events.add(WebAction.back),
        onDone: (t) => unawaited(fetch(t)),
      );
    } else if (view.url != null) {
      body = _Result(view: view, onBack: () => _events.add(WebAction.back), onAgain: () => unawaited(fetch(view.url!)));
    } else {
      body = VrxList(children: [
        const VrxHeader(title: 'Web requests', onBack: Nav.pop),
        VrxRow(glyph: VrxSymbols.add, label: 'New request', onTap: _edit),
        for (final u in view.history)
          VrxRow(label: splitUrl(u).$1, detail: splitUrl(u).$2.isEmpty ? null : splitUrl(u).$2, onTap: () => unawaited(fetch(u))),
      ]);
    }
    return Scaffold(body: SafeArea(child: body));
  }
}

class _Result extends StatelessWidget {
  const _Result({required this.view, required this.onBack, required this.onAgain});

  final WebView view;
  final VoidCallback onBack, onAgain;

  @override
  Widget build(BuildContext context) {
    final space = ScaledSpacing.of(context);
    final r = view.response;
    final mono = TypeRole.caption(context).copyWith(fontFamily: 'Liberation Mono');
    return Column(children: [
      VrxHeader(title: 'Response', onBack: onBack),
      VrxRow(
        label: view.busy ? 'Fetching…' : (r == null ? (view.error ?? '') : '${r.status} ${r.reason} · ${r.millis} ms'),
        onTap: view.busy ? null : onAgain,
      ),
      // the whole address, wrapping at its punctuation
      Padding(
        padding: EdgeInsets.symmetric(horizontal: space.inset, vertical: space.xs),
        child: Text(vrxBreakable(view.url!), style: TypeRole.caption(context)),
      ),
      Expanded(
        child: r == null
            ? (view.busy ? const Center(child: CircularProgressIndicator()) : const SizedBox.shrink())
            : ListView(padding: EdgeInsets.all(space.sm), children: [
                for (final (k, v) in r.headers) Text('$k: $v', style: mono),
                SizedBox(height: space.sm),
                SelectableText(r.body, style: mono),
                if (r.truncated) Text('(the first ${bodyLimit ~/ 1024} KB)', style: TypeRole.caption(context)),
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
    if (await f.exists()) model.history = [for (final u in jsonDecode(await f.readAsString()) as List) '$u'];
  } on Object catch (err) {
    debugPrint('web: history unreadable: $err');
  }
  _events.add(WebAction.historyLoaded);
}
