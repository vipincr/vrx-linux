import 'package:vrx_kit/vrx_kit.dart';

/// Everything the Assistant reacts to (plan 0013 D1: the reducer is the
/// only writer): a signal, or what happened, as data.
sealed class AssistantAction {
  const AssistantAction();

  static const init = AssistantSignal.init;
  static const typing = AssistantSignal.typing;
  static const back = AssistantSignal.back;
  static const answered = AssistantSignal.answered;
  static const cleared = AssistantSignal.cleared;
  static const preparing = AssistantSignal.preparing;
  static const recording = AssistantSignal.recording;
}

/// [answered]: the answer ended (written out, stopped or failed);
/// [preparing]: stt was asked to listen; [recording]: stt said its
/// microphone is open.
enum AssistantSignal implements AssistantAction { init, typing, back, answered, cleared, preparing, recording }

/// Whether a question can be spoken here.
final class AssistantReady implements AssistantAction {
  const AssistantReady({required this.canSpeak});

  final bool canSpeak;
}

/// A question was asked (typed or heard); a blank one, or one while an
/// answer is being written, only closes the typing.
final class AssistantAsk implements AssistantAction {
  const AssistantAsk(this.question);

  final String question;
}

/// A piece of the answer arrived.
final class AssistantPiece implements AssistantAction {
  const AssistantPiece(this.text);

  final String text;
}

/// One sentence about what did not happen; listening stops.
final class AssistantNotice implements AssistantAction {
  const AssistantNotice(this.sentence);

  final String sentence;
}

/// stt's answer: the words, or why there are none.
final class AssistantHeard implements AssistantAction {
  const AssistantHeard({this.text, this.error});

  final String? text;
  final String? error;
}

/// What a person reads when the spoken question has no words (stt's
/// sys.stt.heard error, plan 0011 D18).
String heardSentence(String? error) => switch (error) {
      'nothing-heard' => 'Nothing was heard.',
      'no-microphone' => 'This device has no microphone.',
      _ => 'The speech model could not write that down. The details are in the log.',
    };

class AssistantView {
  const AssistantView({
    required this.turns,
    required this.partial,
    required this.generating,
    required this.typing,
    required this.preparing,
    required this.listening,
    required this.canSpeak,
    required this.notice,
  });

  final List<ChatTurn> turns;

  /// The answer as it is being written.
  final String partial;
  final bool generating;
  final bool typing;

  /// Asked stt to listen; its microphone is not open yet.
  final bool preparing;

  /// stt is recording (it said sys.stt.listening).
  final bool listening;

  /// A speech model is built into this image and the device can hear.
  final bool canSpeak;

  /// One sentence about what did not happen, or null.
  final String? notice;
}

/// The Assistant ships only in an image built with a chat model (meta-vrx,
/// VRX_ML_MODELS), so there is nothing to fetch and no screen to wait on:
/// the conversation is the applet.
class AssistantModel extends StoreModel<AssistantState, AssistantAction, AssistantView> {
  List<ChatTurn> turns = [];
  String partial = '';
  bool generating = false;
  bool typing = false;
  bool preparing = false;
  bool listening = false;
  bool canSpeak = false;
  String? notice;

  @override
  AssistantState get initial => const AssistantState();

  @override
  AssistantAction get bootAction => AssistantAction.init;

  /// A question is taken now: not blank, and no answer being written.
  bool takes(String question) => question.trim().isNotEmpty && !generating;

  @override
  AssistantView reduce(AssistantState state, AssistantAction action) {
    switch (action) {
      case AssistantReady(canSpeak: final can):
        canSpeak = can;
      case AssistantAsk(:final question):
        typing = false;
        if (takes(question)) {
          turns = [...turns, ChatTurn(ChatRole.user, question.trim())];
          partial = '';
          generating = true;
          notice = null;
        }
      case AssistantPiece(:final text):
        partial += text;
      case AssistantNotice(:final sentence):
        notice = sentence;
        preparing = false;
        listening = false;
      case AssistantHeard(:final text, :final error):
        if (listening || preparing) {
          preparing = false;
          listening = false;
          if (text == null || text.trim().isEmpty) notice = heardSentence(error);
        }
      case AssistantSignal.typing:
        typing = true;
      case AssistantSignal.back:
        typing = false;
      case AssistantSignal.answered:
        if (partial.isNotEmpty) turns = [...turns, ChatTurn(ChatRole.assistant, partial)];
        partial = '';
        generating = false;
      case AssistantSignal.cleared:
        turns = [];
        partial = '';
        notice = null;
        generating = false;
      case AssistantSignal.preparing:
        preparing = true;
        notice = null;
      case AssistantSignal.recording:
        if (preparing) {
          preparing = false;
          listening = true;
          notice = null;
        }
      case AssistantSignal.init:
        break;
    }
    return AssistantView(
      turns: List.unmodifiable(turns),
      partial: partial,
      generating: generating,
      typing: typing,
      preparing: preparing,
      listening: listening,
      canSpeak: canSpeak,
      notice: notice,
    );
  }

  @override
  AssistantState get snapshot => const AssistantState();

  /// A conversation is not kept across starts; nothing to restore.
  @override
  void restore(AssistantState snapshot) {}

  @override
  AssistantAction get backAction => AssistantAction.back;

  @override
  bool get atRoot => !typing;

  @override
  Object? get fingerprint =>
      [for (final t in turns) '${t.role.name}:${t.text}', partial, generating, typing, preparing, listening, canSpeak, notice];
}

class AssistantState {
  const AssistantState();
}
