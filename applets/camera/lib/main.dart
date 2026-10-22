import 'dart:async';
import 'dart:math' as math;
import 'dart:io';

import 'package:flutter/material.dart' hide Intent; // vrx's Intent
import 'package:vrx_kit/vrx_kit.dart';

import 'state.dart';

final _events = StreamController<CameraAction>();

/// Where camerad keeps photos (plan 0018 D15; the owner chose /data/photos).
/// The applet reads it only to show the last shot (the photos grant).
String get photoDir => Platform.environment['VRX_PHOTO_DIR'] ?? '/data/photos';

/// Camera: a phone camera (owner, 2026-10-22) — a full-bleed live image
/// with the shutter, the camera switch and Ask the assistant overlaid on
/// it. One client of the headless camerad (plan 0018): the applet owns no
/// device, the viewfinder is a texture the flutter-vrx plugin fills from
/// `camerad.frames`, a photo is a request on `camerad.photos`, and Ask the
/// assistant is the intent `sys.camera.photo` naming the file. Leaving the
/// applet unmounts the viewfinder, which closes the frames channel: a
/// camera nobody watches stops two seconds later, and an open channel
/// would also keep the applet from freezing. With no camera at all the
/// applet is a dark screen and the reason in words — nothing crashes, and
/// the same words cover a camera unplugged after boot.
class CameraApplet extends Applet<CameraSnapshot, CameraAction, CameraView> {
  CameraApplet(this.model, {CameraPhotos? photos, this.send})
      : photos = photos ?? CameraPhotos();

  final CameraModel model;
  final CameraPhotos photos;

  /// Sends `sys.camera.photo` ([Intent.send] on a device).
  final Future<IntentResult> Function(String name, Object? payload)? send;

  @override
  CameraSnapshot get initial => model.initial;

  @override
  CameraAction get bootAction => model.bootAction;

  @override
  CameraView reduce(CameraSnapshot state, CameraAction action) =>
      model.reduce(state, action);

  @override
  CameraSnapshot get snapshot => model.snapshot;

  @override
  void restore(CameraSnapshot snapshot) => model.restore(snapshot);

  @override
  CameraAction? get backAction => model.backAction;

  @override
  Object? get fingerprint => model.fingerprint;

  Future<void> capture(int gen) async {
    _events.add(CameraAction.capture);
    try {
      final shot = await photos.capture(camera: model.picked);
      _events.add(CameraSaved(gen,
          path: shot.path, code: shot.path == null ? 'failed' : null));
    } on CameraError catch (err) {
      _events.add(CameraSaved(gen, code: err.code));
    }
  }

  Future<void> ask(String path) async {
    _events.add(CameraAction.ask);
    try {
      final r = await (send ?? (n, p) => Intent.send(n, p))(
          'sys.camera.photo', {'path': path});
      _events.add(CameraAsked(r.verdict == Verdict.pass ? 'pass' : 'handled'));
    } on Object catch (err) {
      debugPrint('camera: sys.camera.photo: $err');
      _events.add(const CameraAsked('failed'));
    }
  }

  /// Tell camerad which camera, then let the viewfinder open.
  Future<void> select(int gen, String id) async {
    try {
      await photos.select(id);
      _events.add(CameraSelected(gen));
    } on CameraError catch (err) {
      _events.add(CameraStartFailed(gen, err.code));
    }
  }

  @override
  Widget build(BuildContext context, CameraView view) {
    return Scaffold(
      body: Stack(fit: StackFit.expand, children: [
        // always mounted: the session that picks the camera and closes the
        // photos channel when the applet goes
        _Session(view: view, applet: this),
        // the live image, full frame (cover: fill and clip, as a phone does)
        _Finder(view: view),
        // legibility scrims behind the overlaid controls
        const _Scrims(),
        // no camera at all: the dark screen and the reason, over everything
        if (view.empty)
          ColoredBox(
            color: VrxTheme.of(context).page.withValues(alpha: 0.92),
            child: Center(
                child: SingleChildScrollView(
                    child: _Empty(message: view.message))),
          )
        else ...[
          Positioned(top: 0, left: 0, right: 0, child: _TopBar(view: view)),
          Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: _BottomBar(view: view, applet: this)),
        ],
      ]),
    );
  }
}

/// The session that waits for camerad to confirm the camera picked, and
/// closes the photos channel when the applet unmounts.
class _Session extends StatefulWidget {
  const _Session({required this.view, required this.applet});

  final CameraView view;
  final CameraApplet applet;

  @override
  State<_Session> createState() => _SessionState();
}

class _SessionState extends State<_Session> {
  int _selectedFor = -1;

  @override
  void didUpdateWidget(_Session old) {
    super.didUpdateWidget(old);
    _maybeSelect();
  }

  @override
  void initState() {
    super.initState();
    _maybeSelect();
  }

  // a session that waits for camerad to confirm the camera picked
  void _maybeSelect() {
    final v = widget.view;
    final waiting = v.phase == CameraPhase.starting && !v.mount;
    if (waiting && v.selected != null && _selectedFor != v.gen) {
      _selectedFor = v.gen;
      unawaited(widget.applet.select(v.gen, v.selected!));
    }
  }

  @override
  void dispose() {
    widget.applet.photos.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// The picture behind everything, mounted only while a session wants the
/// camera; the surface fills the screen while it is not.
class _Finder extends StatelessWidget {
  const _Finder({required this.view});

  final CameraView view;

  @override
  Widget build(BuildContext context) {
    if (!view.mount) {
      return ColoredBox(color: VrxTheme.of(context).surfaceHigh);
    }
    final gen = view.gen;
    return VrxCameraView(
      key: ValueKey(gen),
      fit: BoxFit.cover,
      onStarted: (s) => _events.add(CameraStarted(gen, s.width, s.height)),
      onFailed: (e) => _events.add(CameraStartFailed(gen, e.code)),
      onEnded: (_) => _events.add(CameraEnded(gen)),
    );
  }
}

/// Vertical gradients, darkest at the bars, so the controls stay readable
/// on any image behind them.
class _Scrims extends StatelessWidget {
  const _Scrims();

  @override
  Widget build(BuildContext context) {
    final page = VrxTheme.of(context).page;
    return Column(children: [
      Expanded(
        flex: 3,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [page.withValues(alpha: 0.55), page.withValues(alpha: 0)],
            ),
          ),
          child: const SizedBox.expand(),
        ),
      ),
      Expanded(
        flex: 4,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [page.withValues(alpha: 0.65), page.withValues(alpha: 0)],
            ),
          ),
          child: const SizedBox.expand(),
        ),
      ),
    ]);
  }
}

/// The camera switch when there is more than one camera — nothing else.
/// The shell's strip already owns Back (the owner, first panel run: "the
/// back button on the viewfinder is huge and useless since the titlebar
/// also has one"); a name title wraps tall on a small panel; a phone
/// camera shows neither.
class _TopBar extends StatelessWidget {
  const _TopBar({required this.view});

  final CameraView view;

  String _next() {
    final i = view.cameras.indexWhere((c) => c.id == view.selected);
    return view.cameras[(i + 1) % view.cameras.length].id;
  }

  @override
  Widget build(BuildContext context) {
    final s = ScaledSpacing.of(context);
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: s.xs, vertical: s.xs),
        child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          if (view.cameras.length > 1)
            _RoundGlyph(
              glyph: VrxSymbols.restart_alt,
              label: 'Switch camera',
              onTap: () => _events.add(CameraPick(_next())),
            ),
        ]),
      ),
    );
  }
}

/// The shutter row: the last photo, the shutter, and Ask the assistant.
class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.view, required this.applet});

  final CameraView view;
  final CameraApplet applet;

  @override
  Widget build(BuildContext context) {
    final s = ScaledSpacing.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.all(s.sm),
        child: LayoutBuilder(builder: (context, box) {
          // the pill is bounded here: a min-size row with a flexible
          // child hands the text unbounded width, and it stops wrapping
          final pillWidth = box.maxWidth - s.inset;
          return Column(mainAxisSize: MainAxisSize.min, children: [
            if (view.message.isNotEmpty)
              _Message(view: view, maxWidth: pillWidth),
            Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
              _LastPhoto(view: view),
              _Shutter(
                hero: true,
                enabled: view.canCapture,
                onTap: view.canCapture
                    ? () => unawaited(applet.capture(view.gen))
                    : null,
              ),
              _Ask(
                enabled: view.canAsk,
                onTap: view.canAsk
                    ? () => unawaited(applet.ask(view.saved!))
                    : null,
              ),
            ]),
          ]);
        }),
      ),
    );
  }
}

/// What happened, a pill over the image: the words wrap between words,
/// they are never cut or split; the signal and Try again, when there is
/// one, sit in a fixed-size row above them.
///
/// The pill sizes to what it says — no scroll, no height cap. A toast
/// that scrolls is a toast nobody can read (the owner's panel photo,
/// 2026-10-22: the last line cut at the capsule's own edge, and the
/// checker blind to it, because a scrollable clips legally); the pill
/// must fit above the shutter row, and the layout matrix proves every
/// sentence does, on every display.
///
/// A toast over a live viewfinder is news, and news goes stale: it
/// leaves on its own after [_MessageState.noticeLife] (the owner:
/// "it does not auto dismiss, just stays there"). The words of a failed
/// session stay — with Try again they are the screen's content — and
/// the model refuses the dismiss for them anyway.
class _Message extends StatefulWidget {
  const _Message({required this.view, required this.maxWidth});

  final CameraView view;
  final double maxWidth;

  @override
  State<_Message> createState() => _MessageState();
}

class _MessageState extends State<_Message> {
  /// How long a toast over the live viewfinder stays: long enough to
  /// read two sentences, short enough that it never becomes furniture.
  static const noticeLife = Duration(seconds: 4);

  Timer? _life;

  @override
  void initState() {
    super.initState();
    _arm();
  }

  @override
  void didUpdateWidget(_Message old) {
    super.didUpdateWidget(old);
    // new news: its time starts now; the same words rebuild without
    // restarting the clock
    if (old.view.message != widget.view.message) _arm();
  }

  void _arm() {
    _life?.cancel();
    _life = widget.view.live
        ? Timer(noticeLife, () => _events.add(CameraAction.dismiss))
        : null;
  }

  @override
  void dispose() {
    _life?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = VrxTheme.of(context);
    final s = ScaledSpacing.of(context);
    final view = widget.view;
    return Align(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: widget.maxWidth),
        child: Container(
          margin: EdgeInsets.only(bottom: s.sm),
          padding: EdgeInsets.symmetric(horizontal: s.md, vertical: s.xs),
          decoration: BoxDecoration(
            color: colors.page.withValues(alpha: 0.8),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: colors.outline, width: Strokes.hairline),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (view.signal != null || view.retry)
                Row(mainAxisSize: MainAxisSize.min, children: [
                  if (view.signal != null)
                    Padding(
                      padding: EdgeInsets.only(right: s.xs),
                      // never taller than the body line it rides beside,
                      // on any display's scale
                      child: Icon(
                        view.signal!.glyph,
                        size: TypeRole.of(context, VrxTypeRole.body).fontSize!,
                        color: colors.textSecondary,
                      ),
                    ),
                  if (view.retry)
                    VrxPress(
                      label: 'Try again',
                      onTap: () => _events.add(CameraAction.retry),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                            minHeight: ScaledSpacing.minInteractive(context)),
                        child: Padding(
                          padding: EdgeInsets.symmetric(horizontal: s.sm),
                          child: Center(
                            child: Text('Try again',
                                style: TypeRole.of(context, VrxTypeRole.body)),
                          ),
                        ),
                      ),
                    ),
                ]),
              Text(
                view.message,
                textAlign: TextAlign.center,
                style: TypeRole.of(context, VrxTypeRole.body),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The shutter: a ring with a filled core, 1.5x the touch minimum
/// across, its pressed and disabled states readable at a glance.
class _Shutter extends StatelessWidget {
  const _Shutter({required this.enabled, this.onTap, this.hero = false});

  final bool enabled;
  final VoidCallback? onTap;

  /// The one control allowed 1.2x the minimum (a phone camera's shutter
  /// is its hero control); everything else is exactly the minimum.
  final bool hero;

  @override
  Widget build(BuildContext context) {
    final colors = VrxTheme.of(context);
    final d = _controlSize(context, factor: hero ? 1.2 : 1.0);
    final ring = Border.fromBorderSide(BorderSide(
      color:
          enabled ? colors.text : colors.textSecondary.withValues(alpha: 0.5),
      width: Strokes.border,
    ));
    return VrxPress(
      label: 'Take photo',
      onTap: onTap,
      child: Container(
        width: d,
        height: d,
        decoration: BoxDecoration(shape: BoxShape.circle, border: ring),
        alignment: Alignment.center,
        child: Container(
          width: d * 0.64,
          height: d * 0.64,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: enabled
                ? colors.text
                : colors.textSecondary.withValues(alpha: 0.3),
          ),
        ),
      ),
    );
  }
}

/// The last shot, bottom-left; a tap on it is v2 (a gallery is out of
/// scope, plan 0018), so it states what it is and does nothing else.
class _LastPhoto extends StatelessWidget {
  const _LastPhoto({required this.view});

  final CameraView view;

  @override
  Widget build(BuildContext context) {
    final colors = VrxTheme.of(context);
    final d = _controlSize(context, factor: 1);
    final box = SizedBox(width: d, height: d);
    if (view.saved == null) {
      return box;
    }
    return Semantics(
      label: 'The last photo',
      image: true,
      child: Container(
        width: d,
        height: d,
        decoration: BoxDecoration(
          border: Border.all(color: colors.outline, width: Strokes.hairline),
          borderRadius: BorderRadius.circular(Strokes.hairline * 4),
        ),
        clipBehavior: Clip.hardEdge,
        child: Image.file(
          File('$photoDir/${view.saved}'),
          fit: BoxFit.cover,
          cacheWidth: 240,
          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
        ),
      ),
    );
  }
}

/// Ask the assistant about the last shot.
class _Ask extends StatelessWidget {
  const _Ask({required this.enabled, this.onTap});

  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = VrxTheme.of(context);
    final d = _controlSize(context, factor: 1);
    return VrxPress(
      label: 'Ask the assistant',
      onTap: onTap,
      child: Container(
        width: d,
        height: d,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: colors.page.withValues(alpha: 0.6),
          border: Border.all(
            color: enabled
                ? colors.text
                : colors.textSecondary.withValues(alpha: 0.5),
            width: Strokes.hairline,
          ),
        ),
        alignment: Alignment.center,
        child: Icon(
          VrxSymbols.smart_toy,
          // relative to the circle it sits in, never to the page's scale
          size: d * 0.45,
          color: enabled
              ? colors.text
              : colors.textSecondary.withValues(alpha: 0.5),
        ),
      ),
    );
  }
}

/// A control's size: the touch minimum on a touch display (never
/// under the minimum itself), an icon's worth when there are no
/// fingers to serve (the chrome's own law for its Back).
double _controlSize(BuildContext context, {double factor = 1.0}) {
  final touch = factor * ScaledSpacing.minInteractive(context);
  final icon = factor * 20.0 * VrxScale.of(context);
  return math.max(touch, icon);
}

/// A round glass button for the bars over the image.
class _RoundGlyph extends StatelessWidget {
  const _RoundGlyph({required this.glyph, required this.label, this.onTap});

  final IconData glyph;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = VrxTheme.of(context);
    final d = _controlSize(context);
    return VrxPress(
      label: label,
      onTap: onTap,
      child: Container(
        width: d,
        height: d,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: colors.page.withValues(alpha: 0.6),
          border: Border.all(color: colors.outline, width: Strokes.hairline),
        ),
        alignment: Alignment.center,
        child: Icon(
          glyph,
          size: d * 0.45,
          color: colors.text,
        ),
      ),
    );
  }
}

/// No camera: why, in words.
class _Empty extends StatelessWidget {
  const _Empty({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final s = ScaledSpacing.of(context);
    return Padding(
      padding: EdgeInsets.all(s.inset),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(VrxSymbols.photo_camera,
            size: 12 * 6.299 * VrxScale.of(context),
            color: VrxTheme.of(context).textSecondary),
        SizedBox(height: s.sm),
        Text(message,
            textAlign: TextAlign.center,
            style: TypeRole.of(context, VrxTypeRole.body)),
      ]),
    );
  }
}

Future<void> main() async {
  final model = CameraModel();
  runApplet(CameraApplet(model), actions: _events.stream);
  // the camera is let go when the applet is not in front (plan 0018 D12): the
  // compositor says hidden when focus or the screen goes, resumed on return
  void follow(AppLifecycleState state) {
    final shown = state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    _events.add(shown ? CameraAction.enter : CameraAction.leave);
  }

  AppLifecycleListener(onStateChange: follow);
  final now = WidgetsBinding.instance.lifecycleState;
  if (now != AppLifecycleState.hidden && now != AppLifecycleState.paused) {
    _events.add(CameraAction.enter);
  }
  CameraService.instance
      .watch()
      .listen((s) => _events.add(CameraListed(s)), onError: (Object _) {});
}
