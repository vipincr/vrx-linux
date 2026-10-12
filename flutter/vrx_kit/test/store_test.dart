import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

/// The reference applet model: the counter from the plan's harness
/// example, spelled out. The same model compiles into an applet and a
/// host test.
class CounterModel implements StoreModel<int, CounterAction, CounterView> {
  int count = 0;
  bool announced = false;

  @override
  int get initial => 0;

  @override
  CounterAction get bootAction => CounterAction.init;

  @override
  CounterView reduce(int state, CounterAction action) {
    switch (action) {
      case CounterAction.init:
        count = 0;
      case CounterAction.tap:
        count += 1;
      case CounterAction.reset:
        count = 0;
    }
    return CounterView(count: count);
  }

  @override
  List<Effect> effects(int state, CounterAction action) {
    switch (action) {
      case CounterAction.tap when !announced:
        announced = true;
        return const [Effect.intent('myapp.first.tap', null)];
      default:
        return const [];
    }
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
    final harness = StoreHarness(CounterModel());
    harness.assertView((v) => v.count == 0);
  });

  test('actions apply in order, one writer', () {
    final harness = StoreHarness(CounterModel());
    harness.dispatch(CounterAction.tap);
    harness.dispatch(CounterAction.tap);
    harness.dispatch(CounterAction.reset);
    harness.dispatch(CounterAction.tap);
    harness.assertView((v) => v.count == 1);
  });

  test('effects fire after their reduce, once each, oldest first', () {
    final harness = StoreHarness(CounterModel());
    harness.dispatch(CounterAction.tap);
    harness.dispatch(CounterAction.tap);
    expect(
      harness.fired,
      const [IntentEffect('myapp.first.tap', null)],
      reason: 'the first tap announces; the second must not re-announce',
    );
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
}
