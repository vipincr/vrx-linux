import 'dart:async';

import 'package:flutter/material.dart' hide Intent; // vrx's Intent
import 'package:vrx_kit/vrx_kit.dart';

import 'state.dart';

final _events = StreamController<AssistantAction>();

/// Assistant: a conversation with the local chat model (plan 0011 D18).
class AssistantApplet extends Applet<AssistantState, AssistantAction, AssistantView> {
  AssistantApplet(this.model, {LocalChat? chat}) : chat = chat ?? LocalChat();

  final AssistantModel model;
  final LocalChat chat;
  StreamSubscription<String>? _answer;

  @override
  AssistantState get initial => model.initial;

  @override
  AssistantAction get bootAction => model.bootAction;

  @override
  AssistantView reduce(AssistantState state, AssistantAction action) => model.reduce(state, action);

  @override
  AssistantState get snapshot => model.snapshot;

  /// Whether a question can be spoken here: a speech model in the image
  /// (stt and its server) and a microphone.
  Future<void> start() async {
    model.canSpeak = await speechInstalled() && await hasMicrophone();
    _events.add(AssistantAction.ready);
  }

  void ask(String question) {
    final q = question.trim();
    model.typing = false;
    if (q.isEmpty || model.generating) {
      _events.add(AssistantAction.back);
      return;
    }
    model
      ..turns = [...model.turns, ChatTurn(ChatRole.user, q)]
      ..partial = ''
      ..generating = true;
    _events.add(AssistantAction.asked);
    _answer = chat.reply(model.turns).listen(
      (piece) {
        model.partial += piece;
        _events.add(AssistantAction.piece);
      },
      onError: (Object err) {
        model.notice = err is LocalChatError ? err.sentence : VrxWords.of(err, context: 'assistant');
        _events.add(AssistantAction.failed);
      },
      onDone: _finish,
    );
  }

  void _finish() {
    if (model.partial.isNotEmpty) model.turns = [...model.turns, ChatTurn(ChatRole.assistant, model.partial)];
    model
      ..partial = ''
      ..generating = false;
    _answer = null;
    _events.add(AssistantAction.answered);
  }

  Future<void> _stop() async {
    await _answer?.cancel();
    _finish();
  }

  Future<void> _speak() async {
    model.listening = true;
    _events.add(AssistantAction.listening);
    try {
      await Intent.send('sys.stt.listen', null);
    } on Object catch (err) {
      model
        ..listening = false
        ..notice = VrxWords.of(err, context: 'assistant');
      _events.add(AssistantAction.failed);
    }
  }

  /// stt's answer: the words, or why there are none.
  void heard(Object? payload) {
    if (!model.listening) return;
    model.listening = false;
    final p = payload is Map ? payload : const {};
    final text = p['text'];
    if (text is String && text.trim().isNotEmpty) {
      _events.add(AssistantAction.heard);
      ask(text);
    } else {
      model.notice = heardSentence(p['error'] as String?);
      _events.add(AssistantAction.heard);
    }
  }

  Future<void> _clear(BuildContext context) async {
    final yes = await vrxConfirm(context,
        title: 'Clear the conversation?', message: 'Every question and answer on this screen will be cleared.', act: 'Clear');
    if (!yes) return;
    await _answer?.cancel();
    model.generating = false;
    _answer = null;
    _events.add(AssistantAction.cleared);
  }

  void _type() {
    model.typing = true;
    _events.add(AssistantAction.typing);
  }

  @override
  Widget build(BuildContext context, AssistantView view) {
    final Widget body;
    if (view.typing) {
      body = VrxTextEntry(
        title: 'Your question',
        initial: '',
        hint: 'Ask anything',
        onBack: () => _events.add(AssistantAction.back),
        onDone: ask,
      );
    } else {
      body = _Conversation(
        view: view,
        onType: _type,
        onSpeak: () => unawaited(_speak()),
        onStop: () => unawaited(_stop()),
        onClear: () => unawaited(_clear(context)),
      );
    }
    return Scaffold(body: SafeArea(child: body));
  }
}

/// The questions and answers, and the ways to ask.
class _Conversation extends StatelessWidget {
  const _Conversation({required this.view, required this.onType, required this.onSpeak, required this.onStop, required this.onClear});

  final AssistantView view;
  final VoidCallback onType, onSpeak, onStop, onClear;

  @override
  Widget build(BuildContext context) {
    final space = ScaledSpacing.of(context);
    final empty = view.turns.isEmpty && view.partial.isEmpty;
    return Column(children: [
      VrxHeader(
        title: 'Assistant',
        onBack: Nav.pop,
        action: empty ? null : VrxIconButton(glyph: VrxSymbols.delete_sweep, onTap: onClear),
      ),
      if (view.notice != null) VrxBanner(text: view.notice),
      Expanded(
        child: empty
            ? Center(
                child: Padding(
                  padding: EdgeInsets.all(space.inset),
                  child: Text('Ask a question. The answer is written on this device.',
                      style: TypeRole.body(context), textAlign: TextAlign.center),
                ),
              )
            : ListView(padding: EdgeInsets.symmetric(horizontal: space.inset, vertical: space.sm), children: [
                for (final t in view.turns) _Turn(who: t.role == ChatRole.user ? 'You' : 'Assistant', text: t.text),
                if (view.generating) _Turn(who: 'Assistant', text: view.partial.isEmpty ? 'Thinking…' : view.partial),
              ]),
      ),
      if (view.generating)
        VrxRow(glyph: VrxSymbols.stop, label: 'Stop the answer', onTap: onStop)
      else if (view.listening)
        const VrxRow(glyph: VrxSymbols.mic, label: 'Listening…')
      else ...[
        VrxRow(glyph: VrxSymbols.keyboard, label: 'Type a question', onTap: onType),
        if (view.canSpeak) VrxRow(glyph: VrxSymbols.mic, label: 'Speak a question', onTap: onSpeak),
      ],
    ]);
  }
}

class _Turn extends StatelessWidget {
  const _Turn({required this.who, required this.text});

  final String who, text;

  @override
  Widget build(BuildContext context) {
    final space = ScaledSpacing.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: space.sm),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(who, style: TypeRole.caption(context)),
        SelectableText(text, style: TypeRole.body(context)),
      ]),
    );
  }
}

Future<void> main() async {
  final model = AssistantModel();
  final applet = AssistantApplet(model);
  runApplet(applet, actions: _events.stream);
  // stt's answers: a told handler, answered at once
  VrxBridge.listen().listen((d) {
    if (d is VrxIntentDelivery && d.name == 'sys.stt.heard') {
      final id = d.id;
      if (id != null) unawaited(VrxBridge.answer(id, handled: true).catchError((Object _) {}));
      applet.heard(d.payload);
    }
  }, onError: (Object err) => debugPrint('assistant: listen: $err'));
  await applet.start();
}
