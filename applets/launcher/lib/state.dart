import 'package:vrx_kit/vrx_kit.dart';

/// Everything the launcher reacts to.
enum LauncherAction {
  init,
  registryChanged,
  appLaunched,
  appFinished,
  searchChanged,
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
  const LauncherView({required this.tiles, required this.query});

  /// The visible tiles: query-filtered, position-ordered.
  final List<Tile> tiles;

  /// The active filter (empty: everything).
  final String query;
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
        break;
    }
    return LauncherView(tiles: _visible(), query: _query);
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
