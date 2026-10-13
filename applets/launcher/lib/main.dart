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

  /// vrxhost's offers replaced the old ones (dispatch
  /// [LauncherAction.offersChanged] after).
  void replaceOffers(List<AppOffer> offers) => _model.offers = offers;

  @override
  LauncherState get initial => _model.initial;

  @override
  LauncherAction get bootAction => _model.bootAction;

  @override
  LauncherView reduce(LauncherState state, LauncherAction action) =>
      _model.reduce(state, action);

  @override
  LauncherState get snapshot => _model.snapshot;

  /// Read the registry and the offers again (after an install, an
  /// uninstall, or coming back to Home with a new drive's apps).
  Future<void> refresh() async {
    final service = AppletsService.installed;
    if (service == null) return;
    try {
      final applets = await service.applets();
      replaceRegistry({
        for (final a in applets) a.id: Tile(id: a.id, name: a.name, position: a.position, icon: a.icon ?? ''),
      });
      _registryActions.add(LauncherAction.registryChanged);
    } on Object catch (err) {
      debugPrint('launcher: registry: $err');
    }
    try {
      replaceOffers(await service.offers());
      _registryActions.add(LauncherAction.offersChanged);
    } on Object catch (err) {
      // no apps grant or no installer: nothing is offered
      debugPrint('launcher: offers: $err');
    }
  }

  Future<void> _offer(BuildContext context, AppOffer o) async {
    if (o.problem != null) {
      _model.error = VrxWords.offerProblem(o.problem!);
      _registryActions.add(LauncherAction.failed);
      return;
    }
    final c = consentFor(o);
    if (!await vrxConfirm(context, title: c.title, message: c.message, act: c.act)) return;
    try {
      await AppletsService.installed?.installOffer(o);
    } on Object catch (err) {
      _model.error = VrxWords.of(err, context: 'launcher: install');
      _registryActions.add(LauncherAction.failed);
    }
    await refresh();
  }

  Future<void> _uninstall(BuildContext context, Tile tile) async {
    final yes = await vrxConfirm(
      context,
      title: 'Uninstall ${tile.name}?',
      message: 'It is removed, with everything it saved.',
      act: 'Uninstall',
    );
    if (!yes) return;
    try {
      await AppletsService.installed?.uninstall(tile.id);
    } on Object catch (err) {
      _model.error = VrxWords.of(err, context: 'launcher: uninstall');
      _registryActions.add(LauncherAction.failed);
    }
    await refresh();
  }

  @override
  Widget build(BuildContext context, LauncherView view) {
    final space = ScaledSpacing.of(context);
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: view.tiles.isEmpty && view.offers.isEmpty
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
                        children: [
                          for (final tile in view.tiles)
                            // a hold uninstalls (the system refuses its own)
                            _Tile(
                              tile: tile,
                              labelHeight: labelHeight,
                              style: label,
                              onTap: () => Nav.push(tile.id),
                              onLongPress: () => unawaited(_uninstall(context, tile)),
                            ),
                          for (final o in view.offers)
                            _Tile(
                              tile: Tile(id: o.id, name: o.name, position: 0, icon: o.problem == null ? 'download' : 'block'),
                              note: o.problem != null ? 'Cannot install' : (o.kind == 'install' ? 'Offered' : 'Update'),
                              labelHeight: labelHeight,
                              style: label,
                              onTap: () => unawaited(_offer(context, o)),
                            ),
                        ],
                      );
                    }),
            ),
            if (view.error != null) VrxBanner(text: view.error, onTap: () {
              _model.error = null;
              _registryActions.add(LauncherAction.failed);
            }),
          ],
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.tile, required this.labelHeight, required this.style, required this.onTap, this.onLongPress, this.note});

  final Tile tile;
  final TextStyle style;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// An offer's word under its name ("Offered", "Update").
  final String? note;

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
      onTap: onTap,
      onLongPress: onLongPress,
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
                    note == null ? tile.name : '${tile.name}\n$note',
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
  await applet.refresh();
  // back at Home: an app may have been offered meanwhile (a drive's apps/)
  AppLifecycleListener(onShow: () => unawaited(applet.refresh()));
}
