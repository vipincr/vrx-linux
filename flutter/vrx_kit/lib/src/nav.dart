/// The vrx back trail, from the applet side. The trail is vrxhost's,
/// not the applet's: Nav asks, vrxhost decides. Raw Navigator is
/// banned (the scan); an applet cannot manipulate the trail.
///
/// A refusal is never silent (plan 0011 D2): [Nav.push] answers with a
/// [NavOutcome], and the sentence for a refused navigation is published
/// on [Nav.refusal], which every applet's host shows as a banner until
/// the next navigation or a tap.
///
/// The runtime installs a delegate that forwards to vrxhost; until
/// one is installed (a host test, a standalone run), Nav refuses with
/// a clear error instead of silently doing nothing.
library;

import 'package:flutter/foundation.dart';

/// What vrxhost answered to a navigation.
class NavOutcome {
  const NavOutcome.done() : sentence = null;

  /// Refused; [sentence] says why, for a person.
  const NavOutcome.refused(String this.sentence);

  final String? sentence;

  bool get done => sentence == null;
}

/// Nav's connection to vrxhost. The flutter-vrx runtime installs this
/// on startup; tests install a recording fake.
abstract interface class NavDelegate {
  /// Push an applet screen onto the trail (at most 3 entries; the
  /// oldest is evicted). [route] is a route the applet declares; one it
  /// does not declare opens its root.
  Future<NavOutcome> push(String applet, {String route});

  /// Pop one entry. An empty trail goes Home.
  Future<NavOutcome> pop();

  /// Clear to the home applet.
  Future<NavOutcome> home();
}

/// The vrx navigation: push, pop, home.
abstract final class Nav {
  static NavDelegate? _delegate;

  /// The sentence for the last refused navigation, until the next one
  /// succeeds or the person dismisses it ([dismiss]).
  static final ValueNotifier<String?> refusal = ValueNotifier<String?>(null);

  /// Install the delegate (the runtime, once, at startup).
  static void install(NavDelegate delegate) => _delegate = delegate;

  /// Push an applet screen onto the trail.
  static Future<NavOutcome> push(String applet, {String route = ''}) =>
      _said(_require().push(applet, route: route));

  /// Pop one entry; an empty trail goes Home.
  static Future<NavOutcome> pop() => _said(_require().pop());

  /// Clear to the home applet.
  static Future<NavOutcome> home() => _said(_require().home());

  /// The person read the refusal.
  static void dismiss() => refusal.value = null;

  static Future<NavOutcome> _said(Future<NavOutcome> outcome) async {
    final o = await outcome;
    refusal.value = o.sentence;
    return o;
  }

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
