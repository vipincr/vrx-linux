import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_check/vrx_check.dart';
import 'package:vrx_kit/vrx_kit.dart';

/// An applet with nothing but a context to open the kit's modals from.
class _Opener extends Applet<int, int, int> {
  BuildContext? context;

  @override
  int get initial => 0;
  @override
  int get bootAction => 0;
  @override
  int reduce(int state, int action) => 0;
  @override
  int get snapshot => 0;
  @override
  Widget build(BuildContext context, int view) => Scaffold(body: Builder(builder: (c) {
        this.context = c;
        return const SizedBox.expand();
      }));
}

/// The kit's modals on every display (plan 0011 D1, the bench on the
/// CM4 + disp28a, 2026-10-14: "Can|cel", "Res|tart", the acts clipped
/// under the dialog). Every route the kit opens is laid out here with
/// the longest words the repo's applets put in one.
/// The dialog as it was laid out before the bench found it (kit at
/// d7a39a5): centred with a wide margin, two chips in halves whatever
/// their words.
class _OldAsk extends Applet<int, int, int> {
  @override
  int get initial => 0;
  @override
  int get bootAction => 0;
  @override
  int reduce(int state, int action) => 0;
  @override
  int get snapshot => 0;
  @override
  Widget build(BuildContext context, int view) {
    final s = ScaledSpacing.of(context);
    return Scaffold(
      body: Center(
        child: Container(
          margin: EdgeInsets.all(s.xl),
          padding: EdgeInsets.all(s.md),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Restart?', style: TypeRole.of(context, VrxTypeRole.title)),
            SizedBox(height: s.sm),
            Text('Every applet closes and the device starts again.', style: TypeRole.of(context, VrxTypeRole.subtext)),
            SizedBox(height: s.lg),
            Row(children: [
              Expanded(child: VrxChip(label: 'Cancel', onTap: () {})),
              SizedBox(width: s.sm),
              Expanded(child: VrxChip(label: 'Restart', filled: true, onTap: () {})),
            ]),
          ]),
        ),
      ),
    );
  }
}

void main() {
  // the rules are seen to fire on the layout the bench photographed
  testWidgets('the old dialog layout breaks its words on disp28a', (tester) async {
    final issues = await checkApplet(tester, _OldAsk(), display: disp28a);
    expect([for (final i in issues) i.rule], contains('broken'));
  });

  final asks = <String, Future<void> Function(BuildContext)>{
    'restart': (c) => vrxConfirm(c, title: 'Restart?', message: 'Every applet closes and the device starts again.', act: 'Restart'),
    'power off': (c) => vrxConfirm(
          c,
          title: 'Power off?',
          message: 'The device turns off. It starts again when its power button or supply says so.',
          act: 'Power off',
        ),
    'forget a long network': (c) => vrxConfirm(
          c,
          title: 'Forget A neighbour with a very long network name?',
          message: 'Its passphrase is deleted and the device stops joining it.',
          act: 'Forget',
        ),
    'replace an app': (c) => vrxConfirm(
          c,
          title: 'Replace Notes 1.2.0 with a different build?',
          message: 'The version is the same but the app is not. Its saved data stays. It is not signed.',
          act: 'Replace',
        ),
    'two acts': (c) => vrxAsk(c, title: 'Recording', message: 'What happens to the take?', acts: ['Keep it', 'Delete the recording']),
  };
  for (final display in allDisplays) {
    for (final a in asks.entries) {
      testWidgets('the ${a.key} modal on ${display.name}', (tester) async {
        final opener = _Opener();
        await expectCleanLayout(tester, opener, display: display, setUp: (t) async {
          final pending = a.value(opener.context!);
          await t.pumpAndSettle();
          // answered by the test's end; nothing waits on it
          pending.ignore();
        });
      });
    }
  }
}
