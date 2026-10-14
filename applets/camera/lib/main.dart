import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' hide Intent; // vrx's Intent
import 'package:vrx_kit/vrx_kit.dart';

import 'state.dart';

final _events = StreamController<CameraAction>();

/// Where camerad keeps photos (plan 0018 D15; the owner chose /data/photos).
/// The applet reads it only to show the last shot (the photos grant).
String get photoDir => Platform.environment['VRX_PHOTO_DIR'] ?? '/data/photos';

/// Camera: a viewfinder and Take photo, one client of the headless camerad
/// (plan 0018). It owns no device: the viewfinder is a texture the
/// flutter-vrx plugin fills from `camerad.frames`, a photo is a request on
/// `camerad.photos`, and Ask the assistant is the intent `sys.camera.photo`
/// naming the file. Leaving the applet unmounts the viewfinder, which
/// closes the frames channel: a camera nobody watches stops two seconds
/// later, and an open channel would also keep the applet from freezing.
class CameraApplet extends Applet<CameraSnapshot, CameraAction, CameraView> {
  CameraApplet(this.model, {CameraPhotos? photos, this.send}) : photos = photos ?? CameraPhotos();

  final CameraModel model;
  final CameraPhotos photos;

  /// Sends `sys.camera.photo` ([Intent.send] on a device).
  final Future<IntentResult> Function(String name, Object? payload)? send;

  @override
  CameraSnapshot get initial => model.initial;

  @override
  CameraAction get bootAction => model.bootAction;

  @override
  CameraView reduce(CameraSnapshot state, CameraAction action) => model.reduce(state, action);

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
      _events.add(CameraSaved(gen, path: shot.path, code: shot.path == null ? 'failed' : null));
    } on CameraError catch (err) {
      _events.add(CameraSaved(gen, code: err.code));
    }
  }

  Future<void> ask(String path) async {
    _events.add(CameraAction.ask);
    try {
      final r = await (send ?? (n, p) => Intent.send(n, p))('sys.camera.photo', {'path': path});
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
      body: SafeArea(
        child: Column(children: [
          const VrxHeader(title: 'Camera', onBack: Nav.pop),
          Expanded(child: _Body(applet: this, view: view)),
        ]),
      ),
    );
  }
}

class _Body extends StatefulWidget {
  const _Body({required this.applet, required this.view});

  final CameraApplet applet;
  final CameraView view;

  @override
  State<_Body> createState() => _BodyState();
}

class _BodyState extends State<_Body> {
  int _selectedFor = -1;

  @override
  void didUpdateWidget(_Body old) {
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
  Widget build(BuildContext context) {
    final view = widget.view;
    final a = widget.applet;
    final s = ScaledSpacing.of(context);
    final controls = _controls(context, view, a);
    // nothing to show: the reason takes the whole body, and scrolls on a panel
    // too small for it
    if (view.empty) {
      return LayoutBuilder(
        builder: (context, box) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: box.maxHeight),
            child: Center(child: _Empty(message: view.message)),
          ),
        ),
      );
    }
    final finder = _Finder(view: view);
    return LayoutBuilder(builder: (context, box) {
      // controls beside the picture on a medium window (wider than tall by a
      // third), below it on a compact one (camera_view.c's rule)
      final beside = box.maxWidth >= box.maxHeight * 4 / 3;
      if (beside) {
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: Padding(padding: EdgeInsets.all(s.sm), child: Center(child: finder))),
          SizedBox(width: box.maxWidth * 0.4, child: ListView(children: controls)),
        ]);
      }
      return Column(children: [
        // the picture never takes more than its share, so Take photo shows
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: box.maxHeight * 0.45),
          child: Padding(padding: EdgeInsets.symmetric(horizontal: s.sm, vertical: s.xs), child: Center(child: finder)),
        ),
        Expanded(child: ListView(children: controls)),
      ]);
    });
  }

  List<Widget> _controls(BuildContext context, CameraView view, CameraApplet a) {
    final s = ScaledSpacing.of(context);
    final colors = VrxTheme.of(context);
    return [
      if (view.message.isNotEmpty && !view.empty)
        if (view.signal != null)
          VrxBanner(text: view.message, signal: view.signal!)
        else
          Padding(
            padding: EdgeInsets.symmetric(horizontal: s.inset, vertical: s.sm),
            child: Text(view.message, style: TypeRole.of(context, VrxTypeRole.body)),
          ),
      if (!view.empty) ...[
        VrxRow(
          glyph: VrxSymbols.photo_camera,
          label: 'Take photo',
          onTap: view.canCapture ? () => unawaited(a.capture(view.gen)) : null,
        ),
        VrxRow(
          glyph: VrxSymbols.smart_toy,
          label: 'Ask the assistant',
          onTap: view.canAsk ? () => unawaited(a.ask(view.saved!)) : null,
        ),
      ],
      if (view.retry)
        VrxRow(glyph: VrxSymbols.restart_alt, label: 'Try again', onTap: () => _events.add(CameraAction.retry)),
      if (view.cameras.length > 1) _switchRow(view),
      if (view.saved != null && !view.empty)
        Padding(
          padding: EdgeInsets.symmetric(horizontal: s.inset, vertical: s.sm),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Semantics(
              label: 'The last photo',
              image: true,
              child: Container(
                decoration: BoxDecoration(border: Border.all(color: colors.outline, width: Strokes.hairline)),
                child: Image.file(
                  File('$photoDir/${view.saved}'),
                  height: 12 * 6.299 * VrxScale.of(context),
                  cacheHeight: 240,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
            ),
          ),
        ),
    ];
  }

  // a tap picks the next camera
  Widget _switchRow(CameraView view) {
    final i = view.cameras.indexWhere((c) => c.id == view.selected);
    final now = view.cameras[i < 0 ? 0 : i];
    final next = view.cameras[(i + 1) % view.cameras.length];
    return VrxRow(label: 'Camera', value: now.name, onTap: () => _events.add(CameraPick(next.id)));
  }
}

/// The picture, 4:3 until the stream says otherwise; mounted only while a
/// session wants the camera.
class _Finder extends StatelessWidget {
  const _Finder({required this.view});

  final CameraView view;

  @override
  Widget build(BuildContext context) {
    if (!view.mount) {
      return AspectRatio(aspectRatio: 4 / 3, child: ColoredBox(color: VrxTheme.of(context).surfaceHigh));
    }
    final gen = view.gen;
    return VrxCameraView(
      key: ValueKey(gen),
      onStarted: (s) => _events.add(CameraStarted(gen, s.width, s.height)),
      onFailed: (e) => _events.add(CameraStartFailed(gen, e.code)),
      onEnded: (_) => _events.add(CameraEnded(gen)),
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
            size: 12 * 6.299 * VrxScale.of(context), color: VrxTheme.of(context).textSecondary),
        SizedBox(height: s.sm),
        Text(message, textAlign: TextAlign.center, style: TypeRole.of(context, VrxTypeRole.body)),
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
    final shown = state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;
    _events.add(shown ? CameraAction.enter : CameraAction.leave);
  }

  AppLifecycleListener(onStateChange: follow);
  final now = WidgetsBinding.instance.lifecycleState;
  if (now != AppLifecycleState.hidden && now != AppLifecycleState.paused) _events.add(CameraAction.enter);
  CameraService.instance.watch().listen((s) => _events.add(CameraListed(s)), onError: (Object _) {});
}
