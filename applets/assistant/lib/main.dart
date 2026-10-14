import 'dart:async';

import 'package:flutter/material.dart' hide Intent; // vrx's Intent
import 'package:vrx_kit/vrx_kit.dart';

import 'state.dart';

/// Assistant: a conversation with the local chat model (plan 0011 D18).
class AssistantApplet extends Applet<AssistantState, AssistantAction, AssistantView> {
  AssistantApplet(this.model, {LocalChat? chat}) : chat = chat ?? LocalChat();

  final AssistantModel model;
  final LocalChat chat;

  /// What happened, for the store (runApplet's actions).
  final events = StreamController<AssistantAction>();
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
    events.add(AssistantReady(canSpeak: await speechInstalled() && await hasMicrophone()));
  }

  void ask(String question) {
    final q = question.trim();
    final taken = model.takes(q);
    events.add(AssistantAsk(q));
    if (!taken) return;
    // the conversation the reducer is about to hold: this question added
    _answer = chat.reply([...model.turns, ChatTurn(ChatRole.user, q)]).listen(
      (piece) => events.add(AssistantPiece(piece)),
      onError: (Object err) =>
          events.add(AssistantNotice(err is LocalChatError ? err.sentence : VrxWords.of(err, context: 'assistant'))),
      onDone: _finish,
    );
  }

  void _finish() {
    _answer = null;
    events.add(AssistantAction.answered);
  }

  Future<void> _stop() async {
    await _answer?.cancel();
    _finish();
  }

  /// Ask stt to listen. "Listening…" waits for stt to say its microphone
  /// is open (sys.stt.listening): words spoken before that are not heard,
  /// so the screen must not claim it earlier (bench, CM4, 2026-10-14).
  Future<void> _speak() async {
    events.add(AssistantAction.preparing);
    try {
      await Intent.send('sys.stt.listen', null);
    } on Object catch (err) {
      events.add(AssistantNotice(VrxWords.of(err, context: 'assistant')));
    }
  }

  /// stt's microphone is open.
  void recording() => events.add(AssistantAction.recording);

  /// stt's answer: the words, or why there are none.
  void heard(Object? payload) {
    final waiting = model.listening || model.preparing;
    final p = payload is Map ? payload : const {};
    final text = p['text'] is String ? p['text'] as String : null;
    events.add(AssistantHeard(text: text, error: p['error'] as String?));
    if (waiting && text != null && text.trim().isNotEmpty) ask(text);
  }

  Future<void> _clear(BuildContext context) async {
    final yes = await vrxConfirm(context,
        title: 'Clear the conversation?', message: 'Every question and answer on this screen will be cleared.', act: 'Clear');
    if (!yes) return;
    await _answer?.cancel();
    _answer = null;
    events.add(AssistantAction.cleared);
  }

  void _type() => events.add(AssistantAction.typing);

  @override
  Widget build(BuildContext context, AssistantView view) {
    final Widget body;
    if (view.typing) {
      body = VrxTextEntry(
        title: 'Your question',
        initial: '',
        hint: 'Ask anything',
        onBack: () => events.add(AssistantAction.back),
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
class _Conversation extends StatefulWidget {
  const _Conversation({required this.view, required this.onType, required this.onSpeak, required this.onStop, required this.onClear});

  final AssistantView view;
  final VoidCallback onType, onSpeak, onStop, onClear;

  @override
  State<_Conversation> createState() => _ConversationState();
}

/// The newest message stays in view while an answer is written, as a
/// chat does, until the person scrolls up to read an older one; back at
/// the bottom, it follows again (bench, CM4, 2026-10-14: the answer grew
/// below the fold).
class _ConversationState extends State<_Conversation> {
  final _scroll = ScrollController();
  bool _following = true;

  @override
  void didUpdateWidget(_Conversation old) {
    super.didUpdateWidget(old);
    if (_following) WidgetsBinding.instance.addPostFrameCallback((_) => _toNewest());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _toNewest() {
    if (!mounted || !_scroll.hasClients) return;
    final p = _scroll.position;
    if (p.pixels < p.maxScrollExtent) _scroll.jumpTo(p.maxScrollExtent);
  }

  /// Where a scroll came to rest says whether to follow: at the bottom
  /// (within a hairline), yes; above it, the person is reading.
  bool _rested(ScrollEndNotification n) {
    _following = n.metrics.pixels >= n.metrics.maxScrollExtent - 1;
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final view = widget.view;
    final space = ScaledSpacing.of(context);
    final empty = view.turns.isEmpty && view.partial.isEmpty;
    if (empty) _following = true;
    return Column(children: [
      VrxHeader(
        title: 'Assistant',
        onBack: Nav.pop,
        action: empty ? null : VrxIconButton(glyph: VrxSymbols.delete_sweep, label: 'Clear the conversation', onTap: widget.onClear),
      ),
      if (view.notice != null) VrxBanner(text: view.notice),
      Expanded(
        child: empty
            ? const _Intro()
            : NotificationListener<ScrollEndNotification>(
                onNotification: _rested,
                child: ListView(
                  controller: _scroll,
                  padding: EdgeInsets.symmetric(horizontal: space.inset, vertical: space.sm),
                  children: [
                    for (final t in view.turns) _Turn(who: t.role == ChatRole.user ? 'You' : 'Assistant', text: t.text),
                    if (view.generating) _Turn(who: 'Assistant', text: view.partial.isEmpty ? 'Thinking…' : view.partial),
                  ],
                ),
              ),
      ),
      if (view.generating)
        VrxRow(glyph: VrxSymbols.stop, label: 'Stop the answer', onTap: widget.onStop)
      else if (view.listening)
        const VrxRow(glyph: VrxSymbols.mic, label: 'Listening…')
      else if (view.preparing)
        const VrxRow(glyph: VrxSymbols.mic, label: 'Opening the mic…')
      else ...[
        VrxRow(glyph: VrxSymbols.keyboard, label: 'Type a question', onTap: widget.onType),
        if (view.canSpeak) VrxRow(glyph: VrxSymbols.mic, label: 'Speak a question', onTap: widget.onSpeak),
      ],
    ]);
  }
}

/// The empty conversation's hint, whole or not at all: under a notice on
/// a small panel there may be no room for it, and half a line reads as a
/// fault (bench, CM4, 2026-10-14). It is a hint; the ways to ask below it
/// say the same.
class _Intro extends StatelessWidget {
  const _Intro();

  static const text = 'Ask a question. The answer is written on this device.';

  @override
  Widget build(BuildContext context) {
    final space = ScaledSpacing.of(context);
    final style = TypeRole.body(context);
    return LayoutBuilder(builder: (context, room) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textAlign: TextAlign.center,
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout(maxWidth: (room.maxWidth - 2 * space.inset).clamp(0, double.infinity));
      final fits = painter.height + 2 * space.inset <= room.maxHeight;
      painter.dispose();
      if (!fits) return const SizedBox.shrink();
      return Center(
        child: Padding(
          padding: EdgeInsets.all(space.inset),
          child: Text(text, style: style, textAlign: TextAlign.center),
        ),
      );
    });
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
  runApplet(applet, actions: applet.events.stream);
  // stt's word: recording, then what it heard; a told handler, answered at
  // once
  VrxBridge.listen().listen((d) {
    if (d is! VrxIntentDelivery || (d.name != 'sys.stt.listening' && d.name != 'sys.stt.heard')) return;
    final id = d.id;
    if (id != null) unawaited(VrxBridge.answer(id, handled: true).catchError((Object _) {}));
    if (d.name == 'sys.stt.listening') {
      applet.recording();
    } else {
      applet.heard(d.payload);
    }
  }, onError: (Object err) => debugPrint('assistant: listen: $err'));
  await applet.start();
}
