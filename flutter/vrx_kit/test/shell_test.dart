import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

/// The shell's place on screen: apps are laid out below the strip the
/// compositor names, with MediaQuery telling them the size they have; the
/// shell reports its strip in device pixels, and the whole screen while
/// its drawer is open.
void main() {
  const shell = MethodChannel('vrx/shell', JSONMethodCodec());
  const insets = MethodChannel('vrx/insets', JSONMethodCodec());
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(shell, (call) async {
      calls.add(call);
      return call.method == 'getInsets' ? {'top': 0} : null;
    });
  });
  tearDown(VrxShell.reset);

  testWidgets('an app sits below the strip and is told its real height', (tester) async {
    tester.view.physicalSize = const Size(480, 640);
    tester.view.devicePixelRatio = 1.5;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    Size? told;
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => VrxInsets(child: child!),
      home: Builder(builder: (context) {
        told = MediaQuery.of(context).size;
        return SizedBox.expand(key: key);
      }),
    ));
    expect(tester.getTopLeft(find.byKey(key)).dy, 0);

    // the compositor pushes 60 device px: 40 logical at 1.5
    VrxShell.listen();
    final message = insets.codec.encodeMethodCall(const MethodCall('insets', {'top': 60}));
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage('vrx/insets', message, (_) {});
    await tester.pump();
    expect(VrxShell.top.value, 60);
    expect(tester.getTopLeft(find.byKey(key)).dy, 40);
    expect(told, const Size(480 / 1.5, 640 / 1.5 - 40));
    expect(calls.map((c) => c.method), contains('getInsets'));
  });

  testWidgets('the shell reports its strip, then the whole screen with the drawer open', (tester) async {
    tester.view.physicalSize = const Size(480, 640);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    Widget region({required bool full}) => Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topCenter,
            child: VrxShellRegion(full: full, child: const SizedBox(height: 30, width: double.infinity)),
          ),
        );
    await tester.pumpWidget(region(full: false));
    await tester.pump();
    final regions = calls.where((c) => c.method == 'setRegion').map((c) => c.arguments).toList();
    expect(regions, [
      {'top': 60, 'full': false},
    ]);

    await tester.pumpWidget(region(full: true));
    await tester.pump();
    expect(calls.where((c) => c.method == 'setRegion').last.arguments, {'top': 60, 'full': true});

    // an unchanged region is not sent again
    final sent = calls.length;
    await tester.pumpWidget(region(full: true));
    await tester.pump();
    expect(calls.length, sent);
  });
}
