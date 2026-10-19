import 'package:flutter_test/flutter_test.dart';


/// The owner, 2026-10-18: after the drawer is dismissed (and after boot),
/// the FIRST swipe down on the strip goes unrecognized; the second opens
/// it. On the bench the same happened with the first drag of a session.
///
/// Both tests are SKIPPED, and the bug they were written for is verified
/// on the board, not here: its cause was the COMPOSITOR swallowing the
/// contact that wakes a dark screen (flutter-vrx c37f40e, now the pinned
/// SRCREV), and the harness has no compositor — the applet-level drag
/// this file simulates never engaged VrxPull in the harness even before
/// that fix (the arena wants the compositor's input routing). The board
/// walk's drawer row, a real finger after a dismiss, is the check of
/// record; making the harness drive the drawer is owed to the kit
/// session (AGENTS.md rule 12: no test that passes on nothing, and none
/// that fails on the harness's own gap either).
void main() {
  testWidgets('the first drag after mount pulls the drawer down', (tester) async {},
      skip: true); // no compositor input routing in the harness; see the header

  testWidgets('after the drawer is shut the first drag opens it again', (tester) async {},
      skip: true); // the board walk's drawer row is the check of record
}
