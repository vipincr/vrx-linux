import 'package:flutter/material.dart' hide Intent; // vrx's Intent
import 'package:vrx_kit/vrx_kit.dart';

import 'state.dart';

/// The launcher applet: the home screen. Every tiled applet in the
/// registry renders as a tile, position-ordered; a tap asks vrxhost
/// to push the applet onto the back trail (Nav, never Navigator).
class LauncherApplet
    extends Applet<LauncherState, LauncherAction, LauncherView> {
  final _model = LauncherModel();

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
            Padding(
              padding: EdgeInsets.all(Spacing.md),
              child: Text('vrx', style: TypeRole.title(context)),
            ),
            Expanded(
              child: view.tiles.isEmpty
                  ? _NoApps()
                  : GridView.count(
                      crossAxisCount: 3,
                      childAspectRatio: 1.0,
                      padding: EdgeInsets.all(Spacing.md),
                      mainAxisSpacing: Spacing.sm,
                      crossAxisSpacing: Spacing.sm,
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
      borderRadius: BorderRadius.circular(Spacing.sm),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(tile.icon, style: TypeRole.display(context)),
          SizedBox(height: Spacing.xs),
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
  runApp(const MaterialApp(home: Scaffold(body: SizedBox.shrink())));
}
