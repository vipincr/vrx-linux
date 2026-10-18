/// The store: vrx's applet model. A pure model (state, actions, a
/// reducer, a derived view model) and a view — joined by one loop that
/// is the only writer of the state.
///
/// All actions queue through one channel; `reduce` runs, then the view
/// is published. The same model compiles into a host test — every
/// applet's decisions are testable without a board.
library;

import 'dart:async';
/// The store contract without any Widget dependency, so the model
/// compiles and tests on any Dart host.
///
/// The model instance owns its state as fields (the evrx-rt style):
/// `reduce` applies the action to the model's state and returns the
/// derived view model — pure in the sense of deterministic and free of
/// side effects. `snapshot` is the serialized state vrxhost keeps when
/// it suspends the applet and restores when it resumes.
abstract class StoreModel<S, A, V> {
  /// The state the model restores from, and the state a fresh model
  /// starts from.
  S get initial;

  /// The action whose reduce produces the first view (an applet's
  /// `Init`): the store seeds itself with
  /// `reduce(initial, bootAction)`.
  A get bootAction;

  /// Pure: apply the action to the state, return the derived view
  /// model. No side effects.
  V reduce(S state, A action);

  /// The model's current state, captured after every reduce — what
  /// suspension preserves and eviction loses.
  S get snapshot;

  /// Facts the store dispatches right after [bootAction], in order (plan
  /// 0013 D1): the world a test or a screenshot starts from goes through
  /// the store loop like any other fact, never around it. Empty on a
  /// device, where the world sends its facts itself.
  List<A> get startingFacts => const [];

  /// Why the screen must stay on now, or null (plan 0010 D3): true only
  /// while something is being watched or must be seen (a ringing alarm).
  /// The store reads it after every reduce and holds or releases the
  /// screen, so a hold never waits for a build: an applet behind another
  /// or under a dark screen is hidden and builds nothing, yet its ring
  /// must still light the screen.
  String? get keepsScreenOn => null;

  /// Put a snapshot back (plan 0013 D2): the fields [snapshot] captured
  /// are the model's again. A model that cannot restore throws; the
  /// harness's restore check then fails, so every applet answers it.
  void restore(S snapshot) =>
      throw UnsupportedError('$runtimeType cannot restore a snapshot (plan 0013 D2)');

  /// The action Back is (the strip's Back, Escape), or null for an applet
  /// with one screen: then it is always at its root (plan 0013 D2).
  A? get backAction => null;

  /// The applet is at its root screen: Back from here leaves it
  /// (Nav.pop), so the harness's Back check stops here.
  bool get atRoot => true;

  /// Which screen the applet shows, by identity: a change of it is a screen
  /// change, and the kit slides it in (plan 0017 D6, VrxSwitch). Compared
  /// deeply, so a list of the flags that name a screen will do. Read-only,
  /// like [atRoot]: it follows the state and is never a field a view writes.
  /// The default is the root and one level over it.
  Object get screen => atRoot ? 0 : 1;

  /// How deep that screen is: 0 at the root, 1 for a screen over it, and so
  /// on. A deeper screen comes from the right, a shallower one from the left,
  /// an equal one cross-fades. Never negative, and a Back never raises it
  /// (the harness checks both).
  int get depth => atRoot ? 0 : 1;

  /// What replay and restore compare (plan 0013 D2): by default the
  /// snapshot, deep-compared. A model whose snapshot leaves out what its
  /// view depends on says what to compare instead.
  Object? get fingerprint => snapshot;
}

/// A field's new value inside a fact or change action (plan 0013 D1), so
/// that null can be the value: `UsbFacts(error: Change(null))` clears the
/// error, while a field left out of the action stays as it was.
final class Change<T> {
  const Change(this.value);

  final T value;

  @override
  bool operator ==(Object other) => other is Change<T> && vrxDeepEquals(other.value, value);

  @override
  int get hashCode => Object.hash(Change, value);

  @override
  String toString() => 'Change($value)';
}

/// Deep equality for what models fingerprint: lists, sets, maps and
/// records element by element, everything else by `==`.
bool vrxDeepEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!vrxDeepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Set && b is Set) {
    return a.length == b.length && a.every((x) => b.any((y) => vrxDeepEquals(x, y)));
  }
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (!b.containsKey(k) || !vrxDeepEquals(a[k], b[k])) return false;
    }
    return true;
  }
  return a == b;
}

/// What a store holds the screen with. The kit installs logind's idle
/// inhibitor ([Store.keeper]); off the board and in host tests it is
/// null, or a fake.
abstract interface class ScreenKeeper {
  /// Keep the screen on, for [why].
  void hold(String why);

  /// Let it go.
  void release();
}

/// The store loop: the only writer of the state.
class Store<S, A, V> {
  /// The screen hold every store uses (one per applet process).
  static ScreenKeeper? keeper;

  Store(this.model) {
    _state = model.initial;
    _apply(model.bootAction);
    model.startingFacts.forEach(dispatch);
  }

  final StoreModel<S, A, V> model;

  late S _state;
  late V _view;
  // sync: a listener attached before dispatch sees the view in the
  // same turn — the loop is deterministic, one writer, one order.
  final StreamController<V> _views = StreamController<V>.broadcast(sync: true);
  final List<A> _pending = <A>[];
  bool _draining = false;
  // the hold this store has open: its keeper, so a later change of
  // [keeper] still releases the one that took it
  ScreenKeeper? _holding;

  /// The current view model.
  V get view => _view;

  /// The model's current state snapshot.
  S get state => _state;

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
    _keep(model.keepsScreenOn);
    _views.add(_view);
  }

  void _keep(String? why) {
    if (why != null && _holding == null) {
      _holding = keeper?..hold(why);
    } else if (why == null && _holding != null) {
      _holding!.release();
      _holding = null;
    }
  }

  void dispose() {
    _keep(null);
    // nobody waits on a disposed store's stream to drain
    unawaited(_views.close());
  }
}

/// The host-runnable test harness: drive a store with actions, assert
/// on views and effects — no board, no engine.
class StoreHarness<S, A, V> {
  StoreHarness(this.model, {this.reduceBudget = defaultReduceBudget})
      : store = Store<S, A, V>(model);

  /// Plan 0008 D18: one action through reduce and effects stays under
  /// this, or the host test fails. A reducer is a pure function on the
  /// event loop; anything slower is I/O or work that belongs in an effect.
  static const defaultReduceBudget = Duration(milliseconds: 2);

  final StoreModel<S, A, V> model;
  final Store<S, A, V> store;
  final Duration reduceBudget;

  /// The actions this harness dispatched, oldest first (not the boot
  /// action): what [verify] replays (plan 0013 D2).
  final List<A> _sent = <A>[];

  /// Dispatch an action; throws when it overruns [reduceBudget].
  void dispatch(A action) {
    _sent.add(action);
    final watch = Stopwatch()..start();
    store.dispatch(action);
    watch.stop();
    if (watch.elapsed > reduceBudget) {
      throw StateError(
        'reduce budget: $action took ${watch.elapsedMicroseconds} µs, '
        'over ${reduceBudget.inMicroseconds} µs (plan 0008 D18)',
      );
    }
  }

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

  /// How many Backs reach the root from anywhere (plan 0013 D2).
  static const backBound = 50;

  /// Plan 0013 D2 (G032): what the store promises, checked over every
  /// state this test reached. [fresh] makes a new model the way the test
  /// made its own; [probes] are actions to try from every state besides
  /// the ones the test sent (an enum's `values`); [routes] are the routes
  /// the applet opens at, through [openAt] (the applet's `onRoute`).
  ///
  /// - totality: every probe, from every reached state, reduces without a
  ///   throw;
  /// - replay: the same actions from [StoreModel.initial] give the same
  ///   fingerprint;
  /// - restore: the snapshot put back into a fresh model round-trips;
  /// - Back to root: from every reached state, Back reaches the root in
  ///   [backBound] steps;
  /// - open-then-back: opened at each route, Back reaches the root in
  ///   [backBound] steps.
  void verify({
    required StoreModel<S, A, V> Function() fresh,
    Iterable<A> probes = const [],
    Iterable<String> routes = const [],
    A? Function(String route)? openAt,
  }) {
    final sent = _sent.toList();
    Store<S, A, V> replayed(int upTo) {
      final s = Store<S, A, V>(fresh());
      for (final a in sent.take(upTo)) {
        s.dispatch(a);
      }
      return s;
    }

    // totality
    final tries = <A>[...probes];
    for (final a in sent) {
      if (!tries.contains(a)) tries.add(a);
    }
    for (var i = 0; i <= sent.length; i++) {
      for (final probe in tries) {
        final s = replayed(i);
        try {
          s.dispatch(probe);
        } catch (err) {
          throw StateError('totality: $probe after ${sent.take(i).toList()} threw: $err (plan 0013 D2)');
        }
      }
    }
    // replay
    final again = replayed(sent.length);
    if (!vrxDeepEquals(again.model.fingerprint, model.fingerprint)) {
      throw StateError('replay: the same actions gave ${again.model.fingerprint}, '
          'not ${model.fingerprint} (plan 0013 D2)');
    }
    // restore
    final saved = model.snapshot;
    final back = fresh();
    try {
      back.restore(saved);
    } catch (err) {
      throw StateError('restore: ${model.runtimeType} did not take its own snapshot back: $err (plan 0013 D2)');
    }
    if (!vrxDeepEquals(back.snapshot, saved)) {
      throw StateError('restore: the snapshot came back as ${back.snapshot}, not $saved (plan 0013 D2)');
    }
    // Back to root
    void toRoot(Store<S, A, V> s, String from, String check) {
      final b = s.model.backAction;
      var steps = 0;
      while (!s.model.atRoot) {
        if (b == null || steps++ >= backBound) {
          throw StateError('$check: $from did not reach the root in $backBound steps (plan 0013 D2)');
        }
        final before = s.model.depth;
        s.dispatch(b);
        if (s.model.depth < 0 || s.model.depth > before) {
          throw StateError('$check: $from: Back took depth from $before to ${s.model.depth}; a Back never goes deeper (plan 0017 D6)');
        }
      }
    }

    for (var i = 0; i <= sent.length; i++) {
      toRoot(replayed(i), 'after ${sent.take(i).toList()}', 'Back');
    }
    // open-then-back
    for (final route in routes) {
      final s = Store<S, A, V>(fresh());
      final open = openAt?.call(route);
      if (open == null) continue;
      try {
        s.dispatch(open);
      } catch (err) {
        throw StateError('open-then-back: opening at "$route" threw: $err (plan 0013 D2)');
      }
      toRoot(s, 'opened at "$route"', 'open-then-back');
    }
  }
}
