/// The screen (plan 0010). The compositor alone turns it off when idle and
/// on at the next touch, click or key, and sets its brightness; no applet
/// switches it. What an applet may do:
///
/// - keep it on while something is being watched, with [VrxKeepScreenOn]
///   (honoured only while the applet is in front, D3);
/// - with the `display` grant (Settings, the shell), change how it
///   behaves: [ScreenSettings], the brightness and the idle timeout in
///   /etc/vrx/display/screen.conf, which the compositor watches.
///
/// Brightness is a position, 0 to 100; the compositor maps it into its
/// own floor-to-full range, so no value written here leaves a person
/// without a screen (D8).
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'settings.dart';

/// Where the screen's settings live: the `display` grant writes here.
const screenDir = '/etc/vrx/display';

/// What the compositor says it can do: `dim=backlight|alpha|none`.
const screenCapsPath = '/run/vrx-ui/screen';

/// How the compositor dims: the backlight's levels, every plane's alpha
/// over black, or not at all (no slider is offered then).
enum VrxDimming { backlight, alpha, none }

/// The screen's settings now.
@immutable
class ScreenState {
  const ScreenState({this.brightness = ScreenSettings.defaultBrightness, this.lightOff = ScreenSettings.defaultLightOff});

  /// The slider's position, 0 to 100 (0 is the compositor's floor, never dark).
  final int brightness;

  /// Seconds without input before the screen goes off; 0 is never.
  final int lightOff;

  @override
  bool operator ==(Object other) => other is ScreenState && other.brightness == brightness && other.lightOff == lightOff;

  @override
  int get hashCode => Object.hash(brightness, lightOff);
}

/// Read, write and watch /etc/vrx/display/screen.conf. Keys this class
/// does not know (the compositor's `output=`) are kept as they are.
class ScreenSettings {
  ScreenSettings({this.dir = screenDir, this.capsPath = screenCapsPath});

  final String dir;
  final String capsPath;

  static const file = 'screen.conf';
  static const defaultBrightness = 100;
  static const defaultLightOff = 120;

  /// The shortest time between two writes while a slider is dragged.
  static const dragInterval = Duration(milliseconds: 100);

  Future<Map<String, String>> _raw() async {
    try {
      return parseSettings(await File('$dir/$file').readAsString());
    } on FileSystemException {
      return const {};
    }
  }

  static ScreenState _parse(Map<String, String> v) => ScreenState(
        brightness: (int.tryParse(v['brightness'] ?? '') ?? defaultBrightness).clamp(0, 100),
        lightOff: math.max(0, int.tryParse(v['light_off'] ?? '') ?? defaultLightOff),
      );

  Future<ScreenState> read() async => _parse(await _raw());

  /// The settings now, and again whenever the file changes.
  Stream<ScreenState> watch() => watchSettingsFile(dir, file, _raw).map(_parse).distinct();

  /// What the compositor can do; [VrxDimming.none] when it has not said.
  Future<VrxDimming> dimming() async {
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

  Future<void> setLightOff(int seconds) => _set('light_off', '${math.max(0, seconds)}');

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
    return _set('brightness', '$v');
  }

  // writes one after another: two renames racing could land the older
  Future<void> _queue = Future.value();

  Future<void> _set(String key, String value) {
    final next = _queue.then((_) async {
      final values = Map.of(await _raw())..[key] = value;
      final b = StringBuffer('# the screen (plan 0010): Settings and the shell write this; the compositor reads it\n');
      for (final e in values.entries) {
        b.writeln('${e.key}=${e.value}');
      }
      await replaceSettingsFile(dir, file, b.toString());
    });
    _queue = next.catchError((Object _) {});
    return next;
  }
}

/// The compositor's side of a hold: one flag per applet, so the holds of
/// one applet are counted here and the flag follows the count.
abstract final class _ScreenHold {
  static const _channel = MethodChannel('vrx/display', JSONMethodCodec());
  static int _count = 0;

  static void take() {
    if (++_count == 1) _send(true);
    debugPrint('vrx: screen held ($_count)');
  }

  static void release() {
    if (_count == 0) return;
    if (--_count == 0) _send(false);
    debugPrint('vrx: screen hold released ($_count)');
  }

  static void _send(bool on) {
    unawaited(_channel.invokeMethod<Object?>('hold', {'on': on}).then((_) {}, onError: (Object err) {
      // off the board there is no compositor to ask
      if (err is! MissingPluginException) debugPrint('vrx: screen hold $on refused: $err');
    }));
  }

  @visibleForTesting
  static int get count => _count;
}

/// Keeps the screen on while it is mounted, and only while this applet is
/// in front (the compositor's rule). Put it round what is watched without
/// being touched (a ringing alarm, a viewfinder), never round a whole
/// applet: a screen nobody releases never goes off. If the screen is off
/// when a hold takes effect, it comes on.
class VrxKeepScreenOn extends StatefulWidget {
  const VrxKeepScreenOn({super.key, required this.child});

  final Widget child;

  /// The holds this applet has open now (tests).
  @visibleForTesting
  static int get holds => _ScreenHold.count;

  @override
  State<VrxKeepScreenOn> createState() => _VrxKeepScreenOnState();
}

class _VrxKeepScreenOnState extends State<VrxKeepScreenOn> {
  @override
  void initState() {
    super.initState();
    _ScreenHold.take();
  }

  @override
  void dispose() {
    _ScreenHold.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
