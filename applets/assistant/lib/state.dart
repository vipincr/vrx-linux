import 'package:vrx_kit/vrx_kit.dart';

enum AssistantAction { init, ready, typing, asked, piece, answered, failed, preparing, listening, heard, cleared, back }

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

  @override
  AssistantView reduce(AssistantState state, AssistantAction action) {
    switch (action) {
      case AssistantAction.back:
        if (typing) typing = false;
      case AssistantAction.cleared:
        turns = [];
        partial = '';
        notice = null;
      case AssistantAction.asked:
      case AssistantAction.preparing:
      case AssistantAction.listening:
        notice = null;
      default:
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
}

class AssistantState {
  const AssistantState();
}
