/// The screen (plan 0010), Linux first: vrx wraps what Linux provides and
/// keeps its own only where Linux has none. The compositor turns the
/// screen off when idle and on at the next touch, click or key; no applet
/// switches it. What an applet may do:
///
/// - keep it on while something is being watched, with [VrxKeepScreenOn]:
///   a logind idle inhibitor, which the compositor honours only while the
///   applet is in front;
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

import 'settings.dart';
import 'system.dart';

/// Where the compositor's screen settings live: the `display` grant
/// writes here.
const screenDir = '/etc/vrx/display';

/// What the compositor says it can do: `dim=backlight|alpha|none`.
const screenCapsPath = '/run/vrx-ui/screen';

/// Where Linux keeps the backlights.
const backlightRoot = '/sys/class/backlight';

/// How the compositor dims: the backlight's levels, every plane's alpha
/// over black, or not at all (no slider is offered then).
enum VrxDimming { backlight, alpha, none }

/// The screen's settings now.
@immutable
class ScreenState {
  const ScreenState({this.brightness = ScreenSettings.defaultBrightness, this.lightOff = ScreenSettings.defaultLightOff});

  /// The slider's position, 0 to 100 (0 is the dimmest, never dark).
  final int brightness;

  /// Seconds without input before the screen goes off; 0 is never.
  final int lightOff;

  @override
  bool operator ==(Object other) => other is ScreenState && other.brightness == brightness && other.lightOff == lightOff;

  @override
  int get hashCode => Object.hash(brightness, lightOff);
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

  /// How often a watched backlight level is read (sysfs raises no
  /// inotify event for it).
  static const backlightPoll = Duration(seconds: 1);

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
    return ScreenState(brightness: brightness, lightOff: lightOff);
  }

  /// The settings now, and again whenever they change: screen.conf by
  /// inotify, a backlight level by a read every [backlightPoll].
  Stream<ScreenState> watch() {
    StreamSubscription<Object?>? file;
    Timer? poll;
    late final StreamController<ScreenState> out;
    Future<void> emit() async {
      final s = await read();
      if (!out.isClosed) out.add(s);
    }

    out = StreamController(
      onListen: () async {
        file = watchSettingsFile(dir, ScreenSettings.file, _raw).listen((_) => emit());
        if (await dimming() == VrxDimming.backlight && !out.isClosed) {
          poll = Timer.periodic(backlightPoll, (_) => emit());
        }
      },
      onCancel: () async {
        poll?.cancel();
        await file?.cancel();
        await out.close();
      },
    );
    return out.stream.distinct();
  }

  Future<void> setLightOff(int seconds) => _setConf('light_off', '${math.max(0, seconds)}');

  /// Set the brightness. While a slider moves ([settled] false) at most
  /// one write in [dragInterval], the last position always written; on
  /// release ([settled] true) at once.
  Future<void> setBrightness(int value, {bool settled = true}) {
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

/// One logind idle inhibitor for the whole applet, open while any
/// [VrxKeepScreenOn] is mounted. Takes and releases run one after another,
/// so a quick release and take never leave two open or none.
abstract final class _Holds {
  static int _count = 0;
  static Future<ScreenHold?> _held = Future.value();

  /// The applet's id: its unit, `vrx-applet@<id>`, sets VRX_APPLET.
  static String get _who => Platform.environment['VRX_APPLET'] ?? 'vrx';

  static void take(String why) {
    if (++_count > 1) return;
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

  static void release() {
    if (_count == 0 || --_count > 0) return;
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

/// Keeps the screen on while it is mounted, and only while this applet is
/// in front (the compositor's rule). Put it round what is watched without
/// being touched (a ringing alarm, a viewfinder), never round a whole
/// applet: a screen nobody releases never goes off. If the screen is off
/// when the hold takes effect, it comes on.
class VrxKeepScreenOn extends StatefulWidget {
  const VrxKeepScreenOn({super.key, required this.child, this.why = 'keep the screen on'});

  final Widget child;

  /// What is being watched, for logind's list (`systemd-inhibit --list`).
  final String why;

  /// The holds this applet has open now (tests).
  @visibleForTesting
  static int get holds => _Holds._count;

  @override
  State<VrxKeepScreenOn> createState() => _VrxKeepScreenOnState();
}

class _VrxKeepScreenOnState extends State<VrxKeepScreenOn> {
  @override
  void initState() {
    super.initState();
    _Holds.take(widget.why);
  }

  @override
  void dispose() {
    _Holds.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
