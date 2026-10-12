/// The store: vrx's applet model. A pure model (state, actions, a
/// reducer, a derived view model), its effects, and a view — joined by
/// one loop that is the only writer of the state.
///
/// All actions queue through one channel; `reduce` runs, then effects
/// fire, then the view is published. The same model compiles into a
/// host test — every applet's decisions are testable without a board.
library;

import 'dart:async';

/// A side effect the store asks the system to perform after a reduce.
/// Effects are the only place an applet touches the world; `reduce`
/// stays pure.
sealed class Effect {
  const Effect();

  /// Send an intent (the signal IPC shape).
  const factory Effect.intent(String name, Object? payload) = IntentEffect;
}

/// Send an intent after the reduce that requested it.
final class IntentEffect implements Effect {
  const IntentEffect(this.name, this.payload);

  final String name;
  final Object? payload;

  @override
  bool operator ==(Object other) =>
      other is IntentEffect && other.name == name && other.payload == payload;

  @override
  int get hashCode => Object.hash(IntentEffect, name, payload);

  @override
  String toString() => 'IntentEffect($name, $payload)';
}

/// The store contract without any Widget dependency, so the model
/// compiles and tests on any Dart host.
///
/// The model instance owns its state as fields (the evrx-rt style):
/// `reduce` applies the action to the model's state and returns the
/// derived view model — pure in the sense of deterministic and free of
/// side effects (effects belong in [StoreModel.effects]). `snapshot`
/// is the serialized state vrxhost keeps when it suspends the applet
/// and restores when it resumes.
abstract class StoreModel<S, A, V> {
  /// The state the model restores from, and the state a fresh model
  /// starts from.
  S get initial;

  /// The action whose reduce produces the first view (an applet's
  /// `Init`): the store seeds itself with
  /// `reduce(initial, bootAction)`, firing its effects too — resident
  /// applets legitimately announce themselves on boot.
  A get bootAction;

  /// Pure: apply the action to the state, return the derived view
  /// model. No side effects.
  V reduce(S state, A action);

  /// Side effects for this action (intents, I/O). Runs after reduce.
  List<Effect> effects(S state, A action) => const [];

  /// The model's current state, captured after every reduce — what
  /// suspension preserves and eviction loses.
  S get snapshot;
}

/// The store loop: the only writer of the state.
class Store<S, A, V> {
  Store(this.model) {
    _state = model.initial;
    _apply(model.bootAction);
  }

  final StoreModel<S, A, V> model;

  late S _state;
  late V _view;
  // sync: a listener attached before dispatch sees the view in the
  // same turn — the loop is deterministic, one writer, one order.
  final StreamController<V> _views = StreamController<V>.broadcast(sync: true);
  final List<A> _pending = <A>[];
  final List<Effect> _fired = <Effect>[];
  bool _draining = false;

  /// The current view model.
  V get view => _view;

  /// The model's current state snapshot.
  S get state => _state;

  /// Every effect fired since construction, oldest first — the
  /// host-test observation channel.
  List<Effect> get fired => List.unmodifiable(_fired);

  /// The published view models.
  Stream<V> get views => _views.stream;

  /// Queue an action; the loop drains in order. Actions dispatched
  /// from inside a reduce or effect queue behind — they never
  /// interleave; one writer, one order.
  void dispatch(A action) {
    _pending.add(action);
    _drain();
  }

  void _drain() {
    if (_draining) return;
    _draining = true;
    try {
      while (_pending.isNotEmpty) {
        _apply(_pending.removeAt(0));
      }
    } finally {
      _draining = false;
    }
  }

  void _apply(A action) {
    _view = model.reduce(_state, action);
    _state = model.snapshot;
    _fired.addAll(model.effects(_state, action));
    _views.add(_view);
  }

  void dispose() {
    _views.close();
  }
}

/// The host-runnable test harness: drive a store with actions, assert
/// on views and effects — no board, no engine.
class StoreHarness<S, A, V> {
  StoreHarness(this.model) : store = Store<S, A, V>(model);

  final StoreModel<S, A, V> model;
  final Store<S, A, V> store;

  /// Dispatch an action.
  void dispatch(A action) => store.dispatch(action);

  /// The current view model.
  V get view => store.view;

  /// Assert on the current view; throws with both sides named.
  void assertView(bool Function(V view) predicate, {String? because}) {
    if (!predicate(store.view)) {
      throw StateError(
        'assertView failed${because == null ? '' : ': $because'} '
        '(view: ${store.view})',
      );
    }
  }

  /// The effects fired so far, oldest first.
  List<Effect> get fired => store.fired;
}
