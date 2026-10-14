import 'package:vrx_kit/vrx_kit.dart';

/// Everything the launcher reacts to.
enum LauncherAction {
  init,
  registryChanged,
  appLaunched,
  appFinished,
  searchChanged,

  /// The offers were read again (plan 0011 D16).
  offersChanged,

  /// Something asked for failed; the banner says why.
  failed,
}

/// One launcher tile.
class Tile {
  const Tile({
    required this.id,
    required this.name,
    required this.position,
    this.icon = '',
  });

  final String id;

  /// What a person reads.
  final String name;

  /// Launcher order (the manifest's display.position).
  final int position;

  /// The manifest's display.icon: a VrxSymbols name (the tile falls
  /// back to the name's initial for an unknown one).
  final String icon;
}

/// What the launcher draws.
class LauncherView {
  const LauncherView({required this.tiles, required this.query, this.offers = const [], this.error});

  /// The visible tiles: query-filtered, position-ordered.
  final List<Tile> tiles;

  /// The active filter (empty: everything).
  final String query;

  /// Apps offered for installing, after the tiles: those that can be
  /// installed, updated or replaced, and those that cannot (with why).
  final List<AppOffer> offers;
  final String? error;
}

/// The consent question for an offer (plan 0011 D16): named for what
/// happens, with what will change, and whether anything proves who made
/// it (plan 0013 D3).
({String title, String message, String act}) consentFor(AppOffer o) {
  final who = o.signed
      ? 'It is signed by a key this device trusts.'
      : 'Nothing proves who made it: this debug system installs apps without checking a signature.';
  return switch (o.kind) {
    'update' => (
        title: 'Update ${o.name} to ${o.version}?',
        message: 'Its saved data stays. $who',
        act: 'Update',
      ),
    'replace' => (
        title: 'Replace ${o.name} ${o.version} with a different build?',
        message: 'The version is the same but the app is not. Its saved data stays. $who',
        act: 'Replace',
      ),
    _ => (
        title: 'Install ${o.name} ${o.version}?',
        message: 'It runs on its own, with none of the system\'s permissions. $who',
        act: 'Install',
      ),
  };
}

/// The launcher model. The registry (vrxhost) feeds the applet list;
/// a registry change (install, remove) is an action like any other.
class LauncherModel
    extends StoreModel<LauncherState, LauncherAction, LauncherView> {
  LauncherModel({Map<String, Tile> registry = const {
    'clock': Tile(id: 'clock', name: 'Clock', position: 3, icon: 'schedule'),
    'settings': Tile(id: 'settings', name: 'Settings', position: 4, icon: 'settings'),
  }})
      : _registry = Map.of(registry),
        _query = '',
        _openApp = null;

  final Map<String, Tile> _registry;
  String _query;
  String? _openApp;

  /// What vrxhost offers for installing (older and same builds left out).
  List<AppOffer> offers = const [];
  String? error;

  @override
  LauncherState get initial => LauncherState(
        registry: Map.of(_registry),
        query: _query,
        openApp: _openApp,
      );

  @override
  LauncherAction get bootAction => LauncherAction.init;

  /// The registry (vrxhost) replaced the applet list.
  void replaceRegistry(Map<String, Tile> tiles) => _registry
    ..clear()
    ..addAll(tiles);

  void search(String query) => _query = query;

  @override
  LauncherView reduce(LauncherState state, LauncherAction action) {
    switch (action) {
      case LauncherAction.init:
      case LauncherAction.registryChanged:
        break;
      case LauncherAction.appLaunched:
        break; // the trail is vrxhost's; the launcher just renders
      case LauncherAction.appFinished:
        _openApp = null;
      case LauncherAction.searchChanged:
      case LauncherAction.offersChanged:
      case LauncherAction.failed:
        break;
    }
    if (action == LauncherAction.registryChanged) error = null;
    return LauncherView(
      tiles: _visible(),
      query: _query,
      offers: [for (final o in offers) if (o.installable || o.problem != null) o],
      error: error,
    );
  }

  List<Tile> _visible() {
    final tiles = _registry.values.where((tile) {
      if (_query.isEmpty) return true;
      return tile.name.toLowerCase().contains(_query.toLowerCase());
    }).toList()
      ..sort((a, b) => a.position.compareTo(b.position));
    return tiles;
  }

  @override
  LauncherState get snapshot => LauncherState(
        registry: Map.of(_registry),
        query: _query,
        openApp: _openApp,
      );
}

/// The launcher state snapshot: the registry and where the user was.
class LauncherState {
  const LauncherState({
    required this.registry,
    required this.query,
    required this.openApp,
  });

  final Map<String, Tile> registry;
  final String query;
  final String? openApp;
}
