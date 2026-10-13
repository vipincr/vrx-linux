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
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: space.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(height: space.xl),
              const _Now(),
              SizedBox(height: space.xl),
              Expanded(
                child: view.tiles.isEmpty
                    ? _NoApps()
                    : LayoutBuilder(builder: (context, box) {
                        // as many columns as fit tiles of two touch
                        // minimums (18mm): two on a 43mm panel, more
                        // on a larger display
                        final columns =
                            (box.maxWidth / (space.touch * 1.8)).floor().clamp(2, 8);
                        final tileWidth =
                            (box.maxWidth - space.md * (columns - 1)) / columns;
                        final label = TypeRole.caption(context);
                        final labelHeight =
                            space.xs + (label.fontSize ?? 14) * 1.4;
                        return GridView.count(
                          crossAxisCount: columns,
                          mainAxisSpacing: space.md,
                          crossAxisSpacing: space.md,
                          childAspectRatio: tileWidth / (tileWidth + labelHeight),
                          children: [
                            for (final tile in view.tiles) _Tile(tile: tile),
                          ],
                        );
                      }),
              ),
            ],
          ),
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

  static const _days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  @override
  Widget build(BuildContext context) {
    final palette = VrxTheme.of(context);
    String two(int n) => n.toString().padLeft(2, '0');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${two(_now.hour)}:${two(_now.minute)}',
          style: TypeRole.display(context).copyWith(
            fontWeight: FontWeight.w300,
            height: 1.0,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        Text(
          '${_days[_now.weekday - 1]}, ${_now.day} ${_months[_now.month - 1]}',
          style: TypeRole.subtext(context).copyWith(color: palette.secondary),
        ),
      ],
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
    return InkWell(
      onTap: () => Nav.push(tile.id),
      borderRadius: BorderRadius.circular(Radii.md * 2),
      child: Column(
        children: [
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: palette.fill.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(Radii.md * 2),
              ),
              child: Center(
                child: glyph != null
                    ? Icon(glyph, color: palette.fill, size: space.touch * 0.75, fill: 1)
                    : Text(
                        tile.name.isEmpty ? '?' : tile.name.characters.first,
                        style: TypeRole.title(context).copyWith(color: palette.fill),
                      ),
              ),
            ),
          ),
          SizedBox(height: space.xs),
          Text(
            tile.name,
            style: TypeRole.caption(context).copyWith(height: 1.2),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
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
        a.id: Tile(id: a.id, name: a.name, position: a.position, icon: a.icon ?? ''),
    });
    actions.add(LauncherAction.registryChanged);
  }, onError: (Object err) => debugPrint('launcher: registry: $err'));
}
