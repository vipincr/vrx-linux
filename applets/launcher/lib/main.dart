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
            // one row, the touch minimum tall: the apps are the screen
            const _Now(),
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
                      final label = TypeRole.caption(context);
                      final labelHeight = space.xs + (label.fontSize ?? 14) * 1.3;
                      return GridView.count(
                        padding: EdgeInsets.fromLTRB(space.inset, space.sm, space.inset, space.inset),
                        crossAxisCount: columns,
                        mainAxisSpacing: space.md,
                        crossAxisSpacing: space.sm,
                        childAspectRatio: tileWidth / (tileWidth + labelHeight),
                        children: [for (final tile in view.tiles) _Tile(tile: tile)],
                      );
                    }),
            ),
          ],
        ),
      ),
    );
  }
}

/// The home screen's time and date, following the wall clock.
class _Now extends StatefulWidget {
  const _Now();

  @override
  State<_Now> createState() => _NowState();
}

class _NowState extends State<_Now> {
  late Timer _timer;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      final now = DateTime.now();
      if (now.minute != _now.minute) setState(() => _now = now);
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  static const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  @override
  Widget build(BuildContext context) {
    final palette = VrxTheme.of(context);
    final space = ScaledSpacing.of(context);
    String two(int n) => n.toString().padLeft(2, '0');
    return Container(
      height: space.touch,
      padding: EdgeInsets.symmetric(horizontal: space.inset),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: palette.line, width: Strokes.hairline))),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            '${two(_now.hour)}:${two(_now.minute)}',
            style: TypeRole.title(context).copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
          ),
          const Spacer(),
          Text(
            '${_days[_now.weekday - 1]} ${_now.day} ${_months[_now.month - 1]}',
            style: TypeRole.subtext(context).copyWith(color: palette.secondary),
          ),
        ],
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.tile});

  final Tile tile;

  @override
  Widget build(BuildContext context) {
    final palette = VrxTheme.of(context);
    final space = ScaledSpacing.of(context);
    final glyph = VrxSymbols.named(tile.icon);
    final radius = BorderRadius.circular(Radii.md * 1.5);
    return InkWell(
      onTap: () => Nav.push(tile.id),
      borderRadius: radius,
      child: Column(
        children: [
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: palette.fill.withValues(alpha: 0.18),
                borderRadius: radius,
              ),
              child: Center(
                child: glyph != null
                    ? LayoutBuilder(
                        builder: (context, box) => Icon(glyph, color: palette.fill, size: box.maxHeight * 0.5, fill: 1),
                      )
                    : Text(
                        tile.name.isEmpty ? '?' : tile.name.characters.first,
                        style: TypeRole.title(context).copyWith(color: palette.fill),
                      ),
              ),
            ),
          ),
          SizedBox(height: space.xs),
          // a long name shrinks to fit the tile rather than being cut
          VrxFitText(tile.name, style: TypeRole.caption(context).copyWith(height: 1.2), maxLines: 1),
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
