import 'package:vrx_kit/vrx_kit.dart';

enum AssistantAction { init, models, progress, typing, asked, piece, answered, failed, listening, heard, cleared, back }

/// What a person reads when the spoken question has no words (stt's
/// sys.stt.heard error, plan 0011 D18).
String heardSentence(String? error) => switch (error) {
      'nothing-heard' => 'Nothing was heard.',
      'no-microphone' => 'This device has no microphone.',
      _ => 'The speech model could not write that down. The details are in the log.',
    };

/// Why a model did not arrive, in a person's words.
String fetchSentence(String? why) => switch (why) {
      'network' => 'The download did not finish. Check the network and try again.',
      'checksum' => 'The download arrived damaged and was thrown away. Try again.',
      'space' => 'There is not enough room on this device for the models.',
      _ => 'The download did not work. The details are in the log.',
    };

/// Megabytes, as a person reads a download.
String megabytes(int bytes) => '${(bytes / 1000000).round()} MB';

class AssistantView {
  const AssistantView({
    required this.ready,
    required this.missing,
    required this.fetching,
    required this.fetched,
    required this.turns,
    required this.partial,
    required this.generating,
    required this.typing,
    required this.listening,
    required this.canSpeak,
    required this.notice,
  });

  /// Every model it needs is on the device.
  final bool ready;

  /// Bytes still to download, for the question.
  final int missing;
  final bool fetching;

  /// Bytes downloaded so far.
  final int fetched;
  final List<ChatTurn> turns;

  /// The answer as it is being written.
  final String partial;
  final bool generating;
  final bool typing;
  final bool listening;
  final bool canSpeak;

  /// One sentence about what did not happen, or null.
  final String? notice;
}

class AssistantModel extends StoreModel<AssistantState, AssistantAction, AssistantView> {
  /// The models it needs: chat always, speech where it can hear.
  List<LocalModel> needed = [];
  Map<String, ModelProgress> progress = {};
  List<ChatTurn> turns = [];
  String partial = '';
  bool generating = false;
  bool typing = false;
  bool listening = false;
  bool canSpeak = false;
  String? notice;

  bool get ready => needed.isNotEmpty && needed.every((m) => progress[m.name]?.state == ModelState.present);

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
      case AssistantAction.listening:
        notice = null;
      default:
        break;
    }
    var missing = 0, fetched = 0;
    var fetching = false;
    for (final m in needed) {
      final p = progress[m.name];
      if (p?.state == ModelState.present) continue;
      missing += m.size - (p?.bytes ?? 0);
      fetched += p?.bytes ?? 0;
      if (p?.state == ModelState.fetching) fetching = true;
    }
    return AssistantView(
      ready: ready,
      missing: missing,
      fetching: fetching,
      fetched: fetched,
      turns: List.unmodifiable(turns),
      partial: partial,
      generating: generating,
      typing: typing,
      listening: listening,
      canSpeak: canSpeak && ready,
      notice: notice,
    );
  }

  @override
  AssistantState get snapshot => const AssistantState();
}

class AssistantState {
  const AssistantState();
}
