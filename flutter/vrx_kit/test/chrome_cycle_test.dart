import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

/// Hide the strip and bring it back (bench 2026-10-13: told an inset of 0
/// while hidden, the app's first frame after was laid out under the strip).
void main() {
  const shell = MethodChannel('vrx/shell', JSONMethodCodec());

  testWidgets('the first frame after giving the screen back is below the strip', (tester) async {
    tester.view.physicalSize = const Size(480, 640);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    addTearDown(VrxShell.reset);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(shell, (call) async {
      if (call.method == 'getInsets') return {'top': 100};
      // a CHROME changes no insets: they stay the strip's height
      return null;
    });
    final entry = ValueNotifier(false);
    final key = GlobalKey();
    VrxShell.listen();
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => VrxInsets(child: child!),
      home: ValueListenableBuilder<bool>(
        valueListenable: entry,
        builder: (context, open, _) => open
            ? const VrxNoChrome(child: SizedBox.expand())
            : SizedBox.expand(key: key),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byKey(key)).dy, 50);

    entry.value = true;
    await tester.pumpAndSettle();
    expect(VrxShell.hidden.value, isTrue);

    entry.value = false;
    // one frame: nothing from the compositor is needed
    await tester.pump();
    await tester.pump();
    expect(VrxShell.hidden.value, isFalse);
    expect(VrxShell.top.value, 100);
    expect(tester.getTopLeft(find.byKey(key)).dy, 50, reason: 'below the strip again');
  });
}
