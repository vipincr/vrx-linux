// An applet's frame timings while profiling is on (plan 0014 D5).
//
// Flutter's own FrameTiming (SchedulerBinding.addTimingsCallback) works
// in a release build: the engine reports each frame's build and raster
// durations, in batches about once a second. The kit registers the
// callback only while vrxhost's profiling fact is on, keeps the window's
// durations, and every 5 s sends vrxhost the window's percentiles and how
// many frames overran the refresh budget in each phase. Nothing runs and
// nothing is kept while profiling is off.

import 'dart:async';
import 'dart:ui' show FrameTiming, PlatformDispatcher;

import 'package:flutter/scheduler.dart';

import 'host.dart';

/// One window's durations, and its summary.
class FrameWindow {
  final List<int> build = [];
  final List<int> raster = [];

  bool get isEmpty => build.isEmpty;

  void add(FrameTiming t) {
    build.add(t.buildDuration.inMicroseconds);
    raster.add(t.rasterDuration.inMicroseconds);
  }

  /// The p-th percentile (nearest rank) of [values]; 0 for none.
  static int percentile(List<int> values, double p) {
    if (values.isEmpty) return 0;
    final sorted = [...values]..sort();
    final rank = (p / 100 * sorted.length).ceil().clamp(1, sorted.length);
    return sorted[rank - 1];
  }

  /// The summary vrxhost's io.vrx.Host.FrameStats takes.
  Map<String, Object> summary({required String route, required int budgetUs}) => {
        'route': route,
        'frames': build.length,
        'build_p50_us': percentile(build, 50),
        'build_p95_us': percentile(build, 95),
        'build_p99_us': percentile(build, 99),
        'raster_p50_us': percentile(raster, 50),
        'raster_p95_us': percentile(raster, 95),
        'raster_p99_us': percentile(raster, 99),
        'over_build': build.where((d) => d > budgetUs).length,
        'over_raster': raster.where((d) => d > budgetUs).length,
        'budget_us': budgetUs,
      };
}

/// The refresh budget in microseconds: one refresh of the display the
/// applet draws on (60 Hz when the engine does not say).
int refreshBudgetUs() {
  final displays = PlatformDispatcher.instance.displays;
  final hz = displays.isEmpty ? 60.0 : displays.first.refreshRate;
  return (1e6 / (hz > 0 ? hz : 60.0)).round();
}

/// Follows the profiling fact; while it is on, aggregates and sends.
class VrxFrameTimings {
  VrxFrameTimings(this.host, {this.window = const Duration(seconds: 5), this.route = ''});

  final AppletsService host;
  final Duration window;

  /// The screen being measured; '' is the applet's root.
  String route;

  FrameWindow _current = FrameWindow();
  Timer? _send;
  StreamSubscription<SystemFacts>? _facts;
  bool _on = false;

  /// Start following vrxhost's facts.
  void start() {
    _facts = host.facts().listen((f) => _set(f.profiling), onError: (Object _) {});
  }

  void _set(bool on) {
    if (on == _on) return;
    _on = on;
    if (on) {
      SchedulerBinding.instance.addTimingsCallback(_onTimings);
      _send = Timer.periodic(window, (_) => flush()); // poll-ok: profiling's 5 s summary window, only while the switch is on
    } else {
      SchedulerBinding.instance.removeTimingsCallback(_onTimings);
      _send?.cancel();
      _send = null;
      _current = FrameWindow();
    }
  }

  void _onTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      _current.add(t);
    }
  }

  /// Send the window and start the next; an empty window (nothing drew)
  /// sends nothing: an idle applet has no frames, not bad ones.
  void flush() {
    final w = _current;
    _current = FrameWindow();
    if (w.isEmpty) return;
    unawaited(host.frameStats(w.summary(route: route, budgetUs: refreshBudgetUs())).catchError((Object _) {}));
  }

  void stop() {
    _set(false);
    unawaited(_facts?.cancel());
  }
}
