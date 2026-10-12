/// The vrx back trail, from the applet side. The trail is vrxhost's,
/// not the applet's: Nav asks, vrxhost decides. Raw Navigator is
/// banned (vrx_lints); an applet cannot manipulate the trail.
///
/// The runtime installs a delegate that forwards to vrxhost; until
/// one is installed (a host test, a standalone run), Nav refuses with
/// a clear error instead of silently doing nothing.
library;

/// Nav's connection to vrxhost. The flutter-vrx runtime installs this
/// on startup; tests install a recording fake.
abstract interface class NavDelegate {
  /// Push an applet screen onto the trail (at most 3 entries; the
  /// oldest is evicted).
  void push(String applet, {String route});

  /// Pop one entry. An empty trail goes Home.
  void pop();

  /// Clear to the home applet.
  void home();
}

/// The vrx navigation: push, pop, home.
abstract final class Nav {
  static NavDelegate? _delegate;

  /// Install the delegate (the runtime, once, at startup).
  static void install(NavDelegate delegate) => _delegate = delegate;

  /// Push an applet screen onto the trail.
  static void push(String applet, {String route = ''}) {
    _require().push(applet, route: route);
  }

  /// Pop one entry; an empty trail goes Home.
  static void pop() => _require().pop();

  /// Clear to the home applet.
  static void home() => _require().home();

  static NavDelegate _require() {
    final delegate = _delegate;
    if (delegate == null) {
      throw StateError(
        'Nav: no delegate installed — vrxhost is not running. '
        'The flutter-vrx runtime installs one at startup; tests install '
        'a recording fake.',
      );
    }
    return delegate;
  }
}
