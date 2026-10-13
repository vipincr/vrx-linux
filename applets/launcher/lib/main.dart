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
    final space = ScaledSpacing.of(context);
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: view.tiles.isEmpty
                  ? _NoApps()
                  : LayoutBuilder(builder: (context, box) {
                      // tiles of about 14mm: three across the 43mm panel,
                      // more on a larger display, never under the touch
                      // minimum
                      final inner = box.maxWidth - 2 * space.inset;
                      final columns = ((inner + space.sm) / (14 * mmToDp * VrxScale.of(context) + space.sm))
                          .floor()
                          .clamp(3, 8);
                      final tileWidth = (inner - space.sm * (columns - 1)) / columns;
                      // every title one size (the owner): the caption size,
                      // or less on a screen where the longest word of any
                      // title would not fit a tile, so lines break between
                      // words; two lines at most, room for two
                      final label = titleStyle(context, view.tiles, tileWidth);
                      final labelHeight = space.xs + (label.fontSize ?? 14) * 1.2 * 2;
                      return GridView.count(
                        padding: EdgeInsets.fromLTRB(space.inset, space.sm, space.inset, space.inset),
                        crossAxisCount: columns,
                        mainAxisSpacing: space.md,
                        crossAxisSpacing: space.sm,
                        childAspectRatio: tileWidth / (tileWidth + labelHeight),
                        children: [for (final tile in view.tiles) _Tile(tile: tile, labelHeight: labelHeight, style: label)],
                      );
                    }),
            ),
          ],
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.tile, required this.labelHeight, required this.style});

  final Tile tile;
  final TextStyle style;

  /// The label's room, the same on every tile so every icon is the same
  /// size whether its name takes one line or two.
  final double labelHeight;

  @override
  Widget build(BuildContext context) {
    final colors = VrxTheme.of(context);
    final space = ScaledSpacing.of(context);
    final glyph = VrxSymbols.named(tile.icon);
    final radius = BorderRadius.circular(Radii.md * 1.5);
    return VrxPress(
      onTap: () => Nav.push(tile.id),
      child: Column(
        children: [
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.surfaceHigh,
                borderRadius: radius,
              ),
              child: Center(
                child: glyph != null
                    ? LayoutBuilder(
                        builder: (context, box) => Icon(glyph, color: colors.primary, size: box.maxHeight * 0.5, fill: 1),
                      )
                    : Text(
                        tile.name.isEmpty ? '?' : tile.name.characters.first,
                        style: TypeRole.title(context).copyWith(color: colors.primary),
                      ),
              ),
            ),
          ),
          SizedBox(
            height: labelHeight,
            child: Padding(
              padding: EdgeInsets.only(top: space.xs),
              // one size on every tile; a long name wraps to a second
              // line and anything past it ends in an ellipsis
              child: Align(
                alignment: Alignment.topCenter,
                child: VrxTruncates(
                  child: Text(
                    tile.name,
                    style: style,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The one style every tile title takes on this screen: the caption,
/// shrunk (to 70% at most) until the longest word of any title fits a
/// tile's width.
TextStyle titleStyle(BuildContext context, List<Tile> tiles, double tileWidth) {
  final base = TypeRole.caption(context).copyWith(height: 1.2);
  final size = base.fontSize ?? 14;
  final scaler = MediaQuery.textScalerOf(context);
  var widest = 0.0;
  for (final t in tiles) {
    for (final word in t.name.split(' ')) {
      final tp = TextPainter(text: TextSpan(text: word, style: base), textDirection: TextDirection.ltr, textScaler: scaler)
        ..layout();
      if (tp.width > widest) widest = tp.width;
      tp.dispose();
    }
  }
  if (widest <= tileWidth) return base;
  return base.copyWith(fontSize: size * (tileWidth / widest).clamp(0.7, 1.0) * 0.98);
}

class _NoApps extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        'No apps are installed.',
        style: TypeRole.body(context),
      ),
    );
  }
}

/// Actions from outside the view (registry changes) for the applet's
/// whole life, so never closed.
final _registryActions = StreamController<LauncherAction>();

Future<void> main() async {
  final applet = LauncherApplet();
  runApplet(applet, actions: _registryActions.stream);
  // the tiles are vrxhost's registry; off-device the model's defaults
  // stay (a desktop `flutter run`)
  final service = AppletsService.installed;
  if (service == null) return;
  try {
    final applets = await service.applets();
    applet.replaceRegistry({
      for (final a in applets)
        a.id: Tile(id: a.id, name: a.name, position: a.position, icon: a.icon ?? ''),
    });
    _registryActions.add(LauncherAction.registryChanged);
  } catch (err) {
    debugPrint('launcher: registry: $err');
  }
}
