/// The screen (plan 0010), Linux first: vrx wraps what Linux provides and
/// keeps its own only where Linux has none. The compositor turns the
/// screen off when idle and on at the next touch, click or key; no applet
/// switches it. What an applet may do:
///
/// - keep it on while something is being watched or must be seen, by its
///   model saying why ([StoreModel.keepsScreenOn]): the store opens a
///   logind idle inhibitor ([LogindScreenKeeper]), which the compositor
///   honours only while the applet is in front;
/// - with the `display` grant (Settings, the shell), change how it
///   behaves through [ScreenSettings]:
///   - the brightness, where the backlight has levels, is the backlight's
///     own sysfs `brightness` (systemd-backlight keeps it across boots);
///     only where the compositor dims by plane alpha (Linux has no
///     software dimming) does it live in /etc/vrx/display/screen.conf;
///   - the idle timeout (`light_off`) is screen.conf's, the compositor's
///     own setting.
///
/// Brightness here is a position, 0 to 100. A backlight level is never
/// written as 0, and the compositor keeps its own floor above that, so no
/// position leaves a person without a screen.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'file.dart';
import 'host.dart';
import 'settings.dart';
import 'store.dart';
import 'system.dart';

/// Where the compositor's screen settings live: the `display` grant
/// writes here.
const screenDir = '/etc/vrx/display';

/// What the compositor says it can do and what input is present:
/// `dim=backlight|alpha|none`, the cascade's steps, `touch=0|1`,
/// `keyboard=0|1` (plan 0013 D6, D7).
const screenCapsPath = '/run/vrx-ui/screen';

/// Where Linux keeps the backlights.
const backlightRoot = '/sys/class/backlight';

/// How the compositor dims: the backlight's levels, every plane's alpha
/// over black, or not at all (no slider is offered then).
enum VrxDimming { backlight, alpha, none }

/// The cascade's steps this board offers after the screen goes off (plan
/// 0012 D13, D14), as the compositor says them in /run/vrx-ui/screen:
/// sleep where a person can wake the board from it and it saves enough,
/// deep sleep (a halt) where an RTC can wake the board for an alarm.
@immutable
class VrxCascade {
  const VrxCascade({this.sleep = false, this.deep = false, this.wakeAlarm = false});

  /// "Sleep after" is offered.
  final bool sleep;

  /// "Power off when idle" is offered.
  final bool deep;

  /// An RTC can wake the board on a timer: an alarm rings through a
  /// power-off.
  final bool wakeAlarm;
}

/// The input the board has, as the compositor says it in
/// /run/vrx-ui/screen (plan 0013 D6, D7): a touchscreen, and a physical
/// keyboard. Absent facts (a host test, an old compositor) read as a
/// touchscreen and no keyboard: assuming density on a touch screen puts a
/// finger on nothing, and a keyboard that never shows strands a field.
@immutable
class VrxInputFacts {
  const VrxInputFacts({this.touch = true, this.keyboard = false});

  final bool touch;
  final bool keyboard;

  static VrxInputFacts parse(Map<String, String> v) =>
      VrxInputFacts(touch: v['touch'] != '0', keyboard: v['keyboard'] == '1');

  @override
  bool operator ==(Object other) => other is VrxInputFacts && other.touch == touch && other.keyboard == keyboard;

  @override
  int get hashCode => Object.hash(touch, keyboard);
}

/// When the on-screen keyboard comes up for a text field (plan 0013 D6):
/// always, or only when no physical keyboard is plugged in (the default).
enum VrxKeyboardMode { show, auto }

/// The screen's settings now.
@immutable
class ScreenState {
  const ScreenState({
    this.brightness = ScreenSettings.defaultBrightness,
    this.lightOff = ScreenSettings.defaultLightOff,
    this.sleepAfter = 0,
    this.deepAfter = 0,
    this.keyboard = VrxKeyboardMode.auto,
    this.reduceMotion = false,
  });

  /// The slider's position, 0 to 100 (0 is the dimmest, never dark).
  final int brightness;

  /// Seconds without input before the screen goes off; 0 is never.
  final int lightOff;

  /// Seconds without input before the system sleeps, and before deep
  /// sleep (a power-off the board wakes from); 0 is never. The compositor
  /// takes a step set no later than the one before it as never.
  final int sleepAfter;
  final int deepAfter;

  /// When the on-screen keyboard shows.
  final VrxKeyboardMode keyboard;

  /// Settings > Display > Reduce motion (plan 0017 D5): the compositor's
  /// client passes it to Flutter as `disableAnimations`, so it reaches every
  /// applet through the engine. It only ever takes motion away.
  final bool reduceMotion;

  @override
  bool operator ==(Object other) =>
      other is ScreenState &&
      other.brightness == brightness &&
      other.lightOff == lightOff &&
      other.sleepAfter == sleepAfter &&
      other.deepAfter == deepAfter &&
      other.keyboard == keyboard &&
      other.reduceMotion == reduceMotion;

  @override
  int get hashCode => Object.hash(brightness, lightOff, sleepAfter, deepAfter, keyboard, reduceMotion);
}

/// The screen's settings, each in its one home: the backlight's sysfs
/// level, or screen.conf where there is no backlight to dim. Keys of
/// screen.conf this class does not know (the compositor's `output=`) are
/// kept as they are.
class ScreenSettings {
  ScreenSettings({this.dir = screenDir, this.capsPath = screenCapsPath, this.backlights = backlightRoot});

  final String dir;
  final String capsPath;
  final String backlights;

  static const file = 'screen.conf';
  static const defaultBrightness = 100;
  static const defaultLightOff = 120;

  /// The shortest time between two writes while a slider is dragged.
  static const dragInterval = Duration(milliseconds: 100);

  VrxDimming? _dim;

  Future<Map<String, String>> _raw() async {
    try {
      return parseSettings(await File('$dir/$file').readAsString());
    } on FileSystemException {
      return const {};
    }
  }

  /// What the compositor can do; [VrxDimming.none] when it has not said.
  /// Read once: the compositor writes it before any applet starts.
  Future<VrxDimming> dimming() async => _dim ??= await _readDimming();

  Future<VrxDimming> _readDimming() async {
    try {
      final v = parseSettings(await File(capsPath).readAsString());
      return switch (v['dim']) {
        'backlight' => VrxDimming.backlight,
        'alpha' => VrxDimming.alpha,
        _ => VrxDimming.none,
      };
    } on FileSystemException {
      return VrxDimming.none;
    }
  }

  VrxCascade? _cascade;

  /// The cascade's steps this board offers; none when the compositor has
  /// not said. Read once, like [dimming].
  Future<VrxCascade> cascade() async => _cascade ??= await _readCascade();

  Future<VrxCascade> _readCascade() async {
    try {
      final v = parseSettings(await File(capsPath).readAsString());
      return VrxCascade(
        sleep: (v['sleep'] ?? 'none') != 'none',
        deep: (v['deep'] ?? 'none') != 'none',
        wakeAlarm: v['wakealarm'] == 'yes',
      );
    } on FileSystemException {
      return const VrxCascade();
    }
  }

  /// The input the board has now, and again whenever a device comes or
  /// goes (the compositor rewrites the file).
  Stream<VrxInputFacts> inputFacts() {
    Future<Map<String, String>> read() async {
      try {
        return parseSettings(await File(capsPath).readAsString());
      } on FileSystemException {
        return const {};
      }
    }

    final slash = capsPath.lastIndexOf('/');
    return watchSettingsFile(capsPath.substring(0, slash), capsPath.substring(slash + 1), read)
        .map(VrxInputFacts.parse)
        .distinct();
  }

  /// The first backlight Linux has (the one the compositor dims).
  Future<Directory?> _backlight() async {
    final root = Directory(backlights);
    if (!await root.exists()) return null;
    final entries = await root.list().toList();
    if (entries.isEmpty) return null;
    entries.sort((a, b) => a.path.compareTo(b.path));
    return Directory(entries.first.path);
  }

  Future<int?> _readInt(String path) async {
    try {
      return int.tryParse((await File(path).readAsString()).trim());
    } on FileSystemException {
      return null;
    }
  }

  /// The backlight's level as a position; null when it reads 0 (the
  /// compositor has turned the screen off: that is not a position).
  Future<int?> _backlightPosition() async {
    final d = await _backlight();
    if (d == null) return null;
    final level = await _readInt('${d.path}/brightness');
    final max = await _readInt('${d.path}/max_brightness');
    if (level == null || max == null || max <= 0 || level <= 0) return null;
    return (100 * level / max).round().clamp(0, 100);
  }

  int? _lastPosition;

  Future<ScreenState> read() async {
    final raw = await _raw();
    final lightOff = math.max(0, int.tryParse(raw['light_off'] ?? '') ?? defaultLightOff);
    final int brightness;
    switch (await dimming()) {
      case VrxDimming.backlight:
        brightness = _lastPosition = await _backlightPosition() ?? _lastPosition ?? defaultBrightness;
      case VrxDimming.alpha:
        brightness = (int.tryParse(raw['brightness'] ?? '') ?? defaultBrightness).clamp(0, 100);
      case VrxDimming.none:
        brightness = defaultBrightness;
    }
    int seconds(String key) => math.max(0, int.tryParse(raw[key] ?? '') ?? 0);
    return ScreenState(
      brightness: brightness,
      lightOff: lightOff,
      sleepAfter: seconds('sleep_after'),
      deepAfter: seconds('deep_after'),
      keyboard: raw['on_screen_keyboard'] == 'show' ? VrxKeyboardMode.show : VrxKeyboardMode.auto,
      reduceMotion: raw['reduce_motion'] == '1',
    );
  }

  /// The settings now, and again whenever they change: screen.conf by
  /// inotify, a backlight level when vrxhost hears the backlight's change
  /// uevent (a fact, plan 0012 D6; sysfs raises no inotify event for it).
  Stream<ScreenState> watch() {
    StreamSubscription<Object?>? file;
    StreamSubscription<Object?>? light;
    late final StreamController<ScreenState> out;
    Future<void> emit() async {
      final s = await read();
      if (!out.isClosed) out.add(s);
    }

    out = StreamController(
      onListen: () async {
        file = watchSettingsFile(dir, ScreenSettings.file, _raw).listen((_) => emit());
        final facts = AppletsService.installed?.facts();
        if (await dimming() == VrxDimming.backlight && !out.isClosed && facts != null) {
          light = facts.map((f) => f.backlight).distinct().skip(1).listen((_) => emit());
        }
      },
      onCancel: () async {
        await light?.cancel();
        await file?.cancel();
        await out.close();
      },
    );
    return out.stream.distinct();
  }

  Future<void> setLightOff(int seconds) => _setConf('light_off', '${math.max(0, seconds)}');

  /// The cascade's later steps (plan 0012 D13): seconds from the last
  /// input, 0 never.
  Future<void> setSleepAfter(int seconds) => _setConf('sleep_after', '${math.max(0, seconds)}');
  Future<void> setDeepAfter(int seconds) => _setConf('deep_after', '${math.max(0, seconds)}');

  /// When the on-screen keyboard shows (plan 0013 D6).
  Future<void> setKeyboard(VrxKeyboardMode mode) => _setConf('on_screen_keyboard', mode.name);

  /// Reduce motion (plan 0017 D5): `reduce_motion=0|1`, the key flutter-vrx
  /// reads (inotify on the directory) to set Flutter's `disableAnimations`.
  Future<void> setReduceMotion({required bool on}) => _setConf('reduce_motion', on ? '1' : '0');

  /// Set the brightness. While a slider moves ([settled] false) at most
  /// one write in [dragInterval], the last position always written; on
  /// release ([settled] true) at once.
  Future<void> setBrightness(int value, {bool settled = true}) {
    if (!_flushes) {
      _flushes = true;
      VrxFile.flushOnStop(_flushBrightness);
    }
    _pendingBrightness = value.clamp(0, 100);
    // a write still waiting is superseded by this one: its caller is done
    _trailing?.cancel();
    _trailing = null;
    _trailingDone?.complete();
    _trailingDone = null;
    final since = _lastBrightnessWrite == null ? null : DateTime.now().difference(_lastBrightnessWrite!);
    if (settled || since == null || since >= dragInterval) return _flushBrightness();
    final done = _trailingDone = Completer<void>();
    _trailing = Timer(dragInterval - since, () {
      _trailingDone = null;
      done.complete(_flushBrightness());
    });
    return done.future;
  }

  int? _pendingBrightness;
  bool _flushes = false;
  DateTime? _lastBrightnessWrite;
  Timer? _trailing;
  Completer<void>? _trailingDone;

  Future<void> _flushBrightness() {
    final v = _pendingBrightness;
    if (v == null) return Future.value();
    _pendingBrightness = null;
    _lastBrightnessWrite = DateTime.now();
    return _queued(() async {
      switch (await dimming()) {
        case VrxDimming.backlight:
          await _writeBacklight(v);
        case VrxDimming.alpha:
          await _writeConf('brightness', '$v');
        case VrxDimming.none:
          break;
      }
    });
  }

  /// A position as a backlight level, linear, never 0 (0 is off).
  static int levelFor(int position, int max) => math.max(1, (max * position.clamp(0, 100) / 100).round());

  Future<void> _writeBacklight(int position) async {
    final d = await _backlight();
    if (d == null) return;
    final max = await _readInt('${d.path}/max_brightness');
    if (max == null || max <= 0) return;
    _lastPosition = position;
    await File('${d.path}/brightness').writeAsString('${levelFor(position, max)}');
  }

  // writes one after another: two renames racing could land the older
  Future<void> _queue = Future.value();

  Future<void> _queued(Future<void> Function() body) {
    final next = _queue.then((_) => body());
    _queue = next.catchError((Object _) {});
    return next;
  }

  Future<void> _setConf(String key, String value) => _queued(() => _writeConf(key, value));

  Future<void> _writeConf(String key, String value) async {
    final values = Map.of(await _raw())..[key] = value;
    final b = StringBuffer('# the screen (plan 0010): Settings and the shell write this; the compositor reads it\n');
    for (final e in values.entries) {
      b.writeln('${e.key}=${e.value}');
    }
    await replaceSettingsFile(dir, file, b.toString());
  }
}

/// The store's screen hold on the board: one logind idle inhibitor for
/// the applet, open while its model says why ([StoreModel.keepsScreenOn]).
/// Takes and releases run one after another, so a quick release and take
/// never leave two open or none.
class LogindScreenKeeper implements ScreenKeeper {
  LogindScreenKeeper();

  Future<ScreenHold?> _held = Future.value();

  /// The applet's id: its unit, `vrx-applet@<id>`, sets VRX_APPLET.
  static String get _who => Platform.environment['VRX_APPLET'] ?? 'vrx';

  @override
  void hold(String why) {
    _held = _held.then((open) async {
      if (open != null) return open;
      try {
        final hold = await VrxSystem.power.holdScreen(who: _who, why: why);
        debugPrint('vrx: screen held by $_who ($why)');
        return hold;
      } on Object catch (err) {
        debugPrint('vrx: screen hold refused: $err');
        return null;
      }
    });
  }

  @override
  void release() {
    _held = _held.then((open) async {
      try {
        await open?.release();
        if (open != null) debugPrint('vrx: screen hold released by $_who');
      } on Object catch (err) {
        debugPrint('vrx: screen hold release: $err');
      }
      return null;
    });
  }
}
