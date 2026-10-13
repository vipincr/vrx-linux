import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

/// The screen's settings file and the hold (plan 0010).
void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('vrx-screen'));
  tearDown(() async => dir.delete(recursive: true));

  test('defaults, clamping, and keys it does not know are kept', () async {
    final s = ScreenSettings(dir: dir.path, capsPath: '${dir.path}/caps');
    expect(await s.read(), const ScreenState(brightness: 100, lightOff: 120));
    // the compositor's own key, and garbage, already in the file
    await File('${dir.path}/screen.conf').writeAsString('output=HDMI-A-1\nbrightness=abc\nlight_off=-5\n');
    expect(await s.read(), const ScreenState(brightness: 100, lightOff: 0));
    await s.setBrightness(250);
    await s.setLightOff(300);
    final text = await File('${dir.path}/screen.conf').readAsString();
    expect(text, contains('output=HDMI-A-1'));
    expect(text, contains('brightness=100'));
    expect(text, contains('light_off=300'));
    await s.setBrightness(-3);
    expect((await s.read()).brightness, 0, reason: '0 is the compositor floor, never dark');
    expect(Directory(dir.path).listSync().map((e) => e.path.split('/').last), ['screen.conf'],
        reason: 'the temporary file was renamed over the old one');
  });

  test('dimming is what the compositor says, none when it has not', () async {
    final s = ScreenSettings(dir: dir.path, capsPath: '${dir.path}/caps');
    expect(await s.dimming(), VrxDimming.none);
    await File('${dir.path}/caps').writeAsString('dim=alpha\n');
    expect(await s.dimming(), VrxDimming.alpha);
    await File('${dir.path}/caps').writeAsString('dim=backlight\n');
    expect(await s.dimming(), VrxDimming.backlight);
    await File('${dir.path}/caps').writeAsString('dim=what\n');
    expect(await s.dimming(), VrxDimming.none);
  });

  test('a drag writes at most once a tenth of a second, and the last position always', () async {
    final s = ScreenSettings(dir: dir.path, capsPath: '${dir.path}/caps');
    final file = File('${dir.path}/screen.conf');
    var writes = 0;
    final watch = dir.watch().listen((e) {
      if (e is FileSystemMoveEvent && (e.destination ?? '').endsWith('/screen.conf')) writes++;
    });
    final moves = [for (var v = 0; v <= 50; v += 5) s.setBrightness(v, settled: false)];
    await Future.wait(moves);
    expect((await s.read()).brightness, 50, reason: 'the last position is written');
    await s.setBrightness(70);
    expect((await s.read()).brightness, 70, reason: 'a release writes at once');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await watch.cancel();
    expect(writes, lessThanOrEqualTo(3), reason: 'eleven moves inside one interval: the first, the trailing one, the release');
    expect(await file.exists(), isTrue);
  });

  test('the watch follows the file', () async {
    final s = ScreenSettings(dir: dir.path, capsPath: '${dir.path}/caps');
    final seen = <ScreenState>[];
    final sub = s.watch().listen(seen.add);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await s.setLightOff(30);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await sub.cancel();
    expect(seen.first, const ScreenState());
    expect(seen.last.lightOff, 30);
  });

  testWidgets('holds are counted: the compositor hears the first and the last', (tester) async {
    final calls = <Object?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('vrx/display', JSONMethodCodec()), (call) async {
      calls.add('${call.method} ${call.arguments}');
      return null;
    });
    Widget tree({required bool outer, required bool inner}) => Directionality(
          textDirection: TextDirection.ltr,
          child: outer
              ? VrxKeepScreenOn(child: inner ? const VrxKeepScreenOn(child: SizedBox()) : const SizedBox())
              : const SizedBox(),
        );
    await tester.pumpWidget(tree(outer: true, inner: false));
    expect(VrxKeepScreenOn.holds, 1);
    await tester.pumpWidget(tree(outer: true, inner: true));
    expect(VrxKeepScreenOn.holds, 2);
    await tester.pumpWidget(tree(outer: true, inner: false));
    expect(VrxKeepScreenOn.holds, 1);
    await tester.pumpWidget(tree(outer: false, inner: false));
    expect(VrxKeepScreenOn.holds, 0);
    expect(calls, ['hold {on: true}', 'hold {on: false}']);
  });
}
