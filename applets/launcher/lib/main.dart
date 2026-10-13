import 'dart:async';

import 'package:flutter/material.dart' hide Intent; // vrx's Intent
import 'package:vrx_kit/vrx_kit.dart';

import 'state.dart';

/// The launcher applet: the home screen. Every tiled applet in the
/// registry renders as a tile, position-ordered; a tap asks vrxhost
/// to push the applet onto the back trail (Nav, never Navigator).
class LauncherApplet
    extends Applet<LauncherState, LauncherAction, LauncherView> {
  final _model = LauncherModel();

  /// vrxhost's registry replaced the applet list (dispatch
  /// [LauncherAction.registryChanged] after).
  void replaceRegistry(Map<String, Tile> tiles) => _model.replaceRegistry(tiles);

  @override
  LauncherState get initial => _model.initial;

  @override
  LauncherAction get bootAction => _model.bootAction;

  @override
  LauncherView reduce(LauncherState state, LauncherAction action) =>
      _model.reduce(state, action);

  @override
  LauncherState get snapshot => _model.snapshot;

  @override
  Widget build(BuildContext context, LauncherView view) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            VrxHeader(title: 'vrx'),
            Expanded(
              child: view.tiles.isEmpty
                  ? _NoApps()
                  : GridView.count(
                      crossAxisCount: 3,
                      childAspectRatio: 1.0,
                      padding: EdgeInsets.all(ScaledSpacing.of(context).md),
                      mainAxisSpacing: ScaledSpacing.of(context).sm,
                      crossAxisSpacing: ScaledSpacing.of(context).sm,
                      children: [
                        for (final tile in view.tiles)
                          _Tile(tile: tile),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.tile});

  final Tile tile;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => Nav.push(tile.id),
      borderRadius: BorderRadius.circular(ScaledSpacing.of(context).sm),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(tile.icon, style: TypeRole.display(context)),
          SizedBox(height: ScaledSpacing.of(context).xs),
          Text(tile.name, style: TypeRole.list(context)),
        ],
      ),
    );
  }
}

class _NoApps extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        'no apps',
        style: TypeRole.body(context),
      ),
    );
  }
}

void main() {
  final applet = LauncherApplet();
  final actions = StreamController<LauncherAction>();
  runApplet(applet, actions: actions.stream);
  // the tiles are vrxhost's registry; off-device the model's defaults
  // stay (a desktop `flutter run`)
  VrxHost.installed?.applets().then((applets) {
    applet.replaceRegistry({
      for (final a in applets)
        a.id: Tile(id: a.id, name: a.name, position: a.position, icon: glyphFor(a)),
    });
    actions.add(LauncherAction.registryChanged);
  }, onError: (Object err) => debugPrint('launcher: registry: $err'));
}

/// The tile glyph: the manifest's icon when it is a glyph, else the
/// name's initial (icon files arrive with the asset pipeline).
String glyphFor(RegistryApplet applet) {
  final icon = applet.icon ?? '';
  if (icon.isNotEmpty && !icon.contains('.')) return icon;
  return applet.name.isEmpty ? '■' : applet.name.characters.first.toUpperCase();
}
