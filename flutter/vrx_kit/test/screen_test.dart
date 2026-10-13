import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

/// A logind that counts the inhibitors it hands out.
class _FakePower implements PowerService {
  final events = <String>[];
  int open = 0;

  @override
  Future<ScreenHold> holdScreen({required String who, required String why}) async {
    open++;
    events.add('take $why');
    return _FakeHold(this);
  }

  @override
  Future<bool> canPowerOff() async => false;
  @override
  Future<void> powerOff() async {}
  @override
  Future<void> reboot() async {}
  @override
  Stream<bool> watchSupplyLow() => const Stream.empty();
}

class _FakeHold implements ScreenHold {
  _FakeHold(this.power);
  final _FakePower power;

  @override
  Future<void> release() async {
    power.open--;
    power.events.add('release');
  }
}

/// The screen's settings, each in its one home, and the hold (plan 0010).
void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('vrx-screen'));
  tearDown(() async => dir.delete(recursive: true));

  ScreenSettings settings({String? dim}) {
    if (dim != null) File('${dir.path}/caps').writeAsStringSync('dim=$dim\n');
    return ScreenSettings(dir: dir.path, capsPath: '${dir.path}/caps', backlights: '${dir.path}/backlight');
  }

  Future<File> backlight(int level, int max) async {
    final d = await Directory('${dir.path}/backlight/panel').create(recursive: true);
    await File('${d.path}/max_brightness').writeAsString('$max\n');
    return File('${d.path}/brightness')..writeAsStringSync('$level\n');
  }

  test('dimming is what the compositor says, none when it has not', () async {
    expect(await settings().dimming(), VrxDimming.none);
    expect(await settings(dim: 'alpha').dimming(), VrxDimming.alpha);
    expect(await settings(dim: 'backlight').dimming(), VrxDimming.backlight);
    expect(await settings(dim: 'what').dimming(), VrxDimming.none);
  });

  test('on a backlight, brightness is the backlight\'s own level, linear, never 0', () async {
    final level = await backlight(255, 255);
    final s = settings(dim: 'backlight');
    expect((await s.read()).brightness, 100);
    await s.setBrightness(50);
    expect((await level.readAsString()).trim(), '128');
    await s.setBrightness(0);
    expect((await level.readAsString()).trim(), '1', reason: '0 is off, which only the compositor does');
    expect(ScreenSettings.levelFor(0, 7), 1);
    expect(ScreenSettings.levelFor(100, 7), 7);
    // the compositor turned the screen off: 0 is not a position
    await s.setBrightness(40);
    await level.writeAsString('0\n');
    expect((await s.read()).brightness, 40);
    expect(await File('${dir.path}/screen.conf').exists(), isFalse, reason: 'one home: not screen.conf');
    await s.setLightOff(30);
    final text = await File('${dir.path}/screen.conf').readAsString();
    expect(text, contains('light_off=30'));
    expect(text, isNot(contains('brightness')));
  });

  test('dimmed by alpha, brightness is screen.conf\'s; keys it does not know are kept', () async {
    final s = settings(dim: 'alpha');
    expect(await s.read(), const ScreenState(brightness: 100, lightOff: 120));
    await File('${dir.path}/screen.conf').writeAsString('output=HDMI-A-1\nbrightness=abc\nlight_off=-5\n');
    expect(await s.read(), const ScreenState(brightness: 100, lightOff: 0));
    await s.setBrightness(250);
    await s.setLightOff(300);
    final text = await File('${dir.path}/screen.conf').readAsString();
    expect(text, contains('output=HDMI-A-1'));
    expect(text, contains('brightness=100'));
    expect(text, contains('light_off=300'));
    await s.setBrightness(-3);
    expect((await s.read()).brightness, 0);
    expect(Directory(dir.path).listSync().map((e) => e.path.split('/').last).toSet(), {'screen.conf', 'caps'},
        reason: 'the temporary file was renamed over the old one');
  });

  test('a drag writes at most once a tenth of a second, and the last position always', () async {
    final s = settings(dim: 'alpha');
    var writes = 0;
    final watch = dir.watch().listen((e) {
      if (e is FileSystemMoveEvent && (e.destination ?? '').endsWith('/screen.conf')) writes++;
    });
    await Future.wait([for (var v = 0; v <= 50; v += 5) s.setBrightness(v, settled: false)]);
    expect((await s.read()).brightness, 50, reason: 'the last position is written');
    await s.setBrightness(70);
    expect((await s.read()).brightness, 70, reason: 'a release writes at once');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await watch.cancel();
    expect(writes, lessThanOrEqualTo(3), reason: 'eleven moves inside one interval: the first, the trailing one, the release');
  });

  test('the watch follows screen.conf', () async {
    final s = settings(dim: 'alpha');
    final seen = <ScreenState>[];
    final sub = s.watch().listen(seen.add);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await s.setLightOff(30);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await sub.cancel();
    expect(seen.first, const ScreenState());
    expect(seen.last.lightOff, 30);
  });

  // plan 0010 D3, after the bench (2026-10-14): a hold is the model's
  // state, read by the store after a reduce; no build is involved, so a
  // hidden applet's ring still takes it
  test("the store holds the screen while its model says why, through one inhibitor", () async {
    final power = _FakePower();
    VrxSystem.install(power: power);
    final keeper = LogindScreenKeeper();
    Store.keeper = keeper;
    addTearDown(() => Store.keeper = null);
    final model = _Ringing();
    final store = Store<int, String, int>(model);
    await pumpEventQueue();
    expect(power.open, 0);
    store.dispatch('ring');
    await pumpEventQueue();
    expect(power.open, 1);
    store.dispatch('ring'); // still ringing: no second inhibitor
    await pumpEventQueue();
    expect(power.open, 1);
    store.dispatch('stop');
    await pumpEventQueue();
    expect(power.open, 0);
    // a stop and a ring in one turn: still exactly one, in order
    store
      ..dispatch('ring')
      ..dispatch('stop')
      ..dispatch('ring');
    await pumpEventQueue();
    expect(power.open, 1);
    store.dispose();
    await pumpEventQueue();
    expect(power.open, 0, reason: 'a disposed store lets go');
    expect(power.events, ['take a ring', 'release', 'take a ring', 'release', 'take a ring', 'release']);
  });
}

class _Ringing extends StoreModel<int, String, int> {
  bool ringing = false;

  @override
  int get initial => 0;
  @override
  String get bootAction => 'init';
  @override
  int reduce(int state, String action) {
    if (action == 'ring') ringing = true;
    if (action == 'stop') ringing = false;
    return ringing ? 1 : 0;
  }

  @override
  int get snapshot => 0;
  @override
  String? get keepsScreenOn => ringing ? 'a ring' : null;
}
