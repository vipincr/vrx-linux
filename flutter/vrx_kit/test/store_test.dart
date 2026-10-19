import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

/// The reference applet model: the counter from the plan's harness
/// example, spelled out. The same model compiles into an applet and a
/// host test.
class CounterModel extends StoreModel<int, CounterAction, CounterView> {
  int count = 0;

  /// What the boot action seeds the count from (a model loads its
  /// snapshot here). Observable, so the boot-action test proves the
  /// dispatch happened rather than passing on the initial value (TST-23,
  /// review 2026-10-17).
  int seed = 0;

  @override
  int get initial => 0;

  @override
  CounterAction get bootAction => CounterAction.init;

  @override
  CounterView reduce(int state, CounterAction action) {
    switch (action) {
      case CounterAction.init:
        count = seed;
      case CounterAction.tap:
        count += 1;
      case CounterAction.reset:
        count = 0;
    }
    return CounterView(count: count);
  }

  @override
  int get snapshot => count;
}

enum CounterAction { init, tap, reset }

class CounterView {
  const CounterView({required this.count});

  final int count;

  @override
  String toString() => 'CounterView(count: $count)';
}

void main() {
  test('tapping increments the counter (the plan\'s harness example)', () {
    final harness = StoreHarness(CounterModel());
    harness.dispatch(CounterAction.tap);
    harness.assertView((v) => v.count == 1);
  });

  test('the boot action seeds the initial view', () {
    // the seed is not the initial value, so this fails if the boot
    // action never dispatched (TST-23: it once passed either way)
    final harness = StoreHarness(CounterModel()..seed = 7);
    harness.assertView((v) => v.count == 7,
        because: 'the boot action dispatched and seeded the view');
  });

  test('actions apply in order, one writer', () {
    final harness = StoreHarness(CounterModel());
    harness.dispatch(CounterAction.tap);
    harness.dispatch(CounterAction.tap);
    harness.dispatch(CounterAction.reset);
    harness.dispatch(CounterAction.tap);
    harness.assertView((v) => v.count == 1);
  });

  test('the store snapshot tracks the model state', () {
    final store = Store(CounterModel());
    expect(store.state, 0);
    store.dispatch(CounterAction.tap);
    expect(store.state, 1);
  });

  test('views publish in order', () {
    final store = Store(CounterModel());
    final views = <int>[];
    store.views.listen((v) => views.add(v.count));
    store.dispatch(CounterAction.tap);
    store.dispatch(CounterAction.tap);
    expect(views, const [1, 2], reason: 'one view per action, in order');
  });

  group("the store's promises, checked (plan 0013 D2, G032)", () {
    StoreHarness<int, String, int> driven(PromiseModel Function() make) {
      final h = StoreHarness<int, String, int>(make());
      for (final a in ['tap', 'in', 'in', 'out']) {
        h.dispatch(a);
      }
      return h;
    }

    test('a model that keeps every promise passes', () {
      driven(PromiseModel.new).verify(fresh: PromiseModel.new, probes: const ['tap'], routes: const ['deep'],
          openAt: (r) => r == 'deep' ? 'in' : null);
    });

    test('totality: an action that throws from a reached state fails', () {
      expect(() => driven(() => PromiseModel(throwsOnTap: true)).verify(fresh: () => PromiseModel(throwsOnTap: true)),
          throwsA(isA<StateError>().having((e) => e.message, 'message', contains('totality'))));
    });

    test('replay: a model that reads the clock does not replay', () {
      var n = 0;
      expect(() => driven(() => PromiseModel(noise: () => n++)).verify(fresh: () => PromiseModel(noise: () => n++)),
          throwsA(isA<StateError>().having((e) => e.message, 'message', contains('replay'))));
    });

    test('restore: a model that drops its snapshot fails', () {
      expect(() => driven(() => PromiseModel(forgets: true)).verify(fresh: () => PromiseModel(forgets: true)),
          throwsA(isA<StateError>().having((e) => e.message, 'message', contains('restore'))));
    });

    test('Back: a model Back cannot leave fails', () {
      expect(() => driven(() => PromiseModel(stuck: true)).verify(fresh: () => PromiseModel(stuck: true)),
          throwsA(isA<StateError>().having((e) => e.message, 'message', contains('Back'))));
    });

    test('open-then-back: a route Back cannot leave fails', () {
      expect(
          () => driven(() => PromiseModel(trapRoute: true)).verify(
              fresh: () => PromiseModel(trapRoute: true), routes: const ['trap'], openAt: (_) => 'trap'),
          throwsA(isA<StateError>().having((e) => e.message, 'message', contains('open-then-back'))));
    });

    test('a snapshot that will not restore leaves the model at its initial state', () {
      final bad = PromiseModel(rejects: true);
      expect(() => bad.restore(7), throwsA(anything), reason: 'the snapshot is rejected');
      expect(bad.snapshot, 0, reason: 'a rejected restore leaves the state alone');
      final good = PromiseModel();
      good.restore(2);
      expect(good.snapshot, 2, reason: 'a good snapshot is taken back');
    });
  });
}

/// A model with screens (depth) built to keep, or break, each promise.
class PromiseModel extends StoreModel<int, String, int> {
  PromiseModel({
    this.throwsOnTap = false,
    this.noise,
    this.forgets = false,
    this.stuck = false,
    this.trapRoute = false,
    this.rejects = false,
  });

  final bool throwsOnTap, forgets, stuck, trapRoute, rejects;
  final int Function()? noise;
  @override
  int depth = 0;
  int taps = 0;
  bool trapped = false;

  @override
  int get initial => 0;

  @override
  String get bootAction => 'init';

  @override
  int reduce(int state, String action) {
    switch (action) {
      case 'in':
        depth++;
      case 'out':
        if (!stuck && depth > 0) depth--;
        if (!stuck && !trapRoute) trapped = false;
      case 'trap':
        trapped = true;
      case 'tap':
        if (throwsOnTap && depth > 1) throw StateError('tap at depth $depth');
        taps += noise?.call() ?? 1;
    }
    return depth;
  }

  @override
  int get snapshot => depth;

  @override
  void restore(int snapshot) {
    if (rejects) throw const FormatException('truncated');
    if (!forgets) depth = snapshot;
  }

  @override
  String get backAction => 'out';

  @override
  bool get atRoot => depth == 0 && !(trapRoute && trapped);

  @override
  Object? get fingerprint => (depth, taps);
}
