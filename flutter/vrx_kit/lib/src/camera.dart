/// The camera, from an applet's side (plan 0018). One headless service,
/// camerad, owns the sensor or the webcam; an applet never opens a device.
/// What it may do instead:
///
///  * read what is true now: [CameraService] watches camerad's one state
///    file, `/run/vrx/camera/state.json` (which cameras exist, whether one
///    is running, why there is none), the "a value that stays true until it
///    changes" shape of docs/03-ipc;
///  * ask for a photo: [CameraPhotos] over the channel `camerad.photos`
///    (the `camera-use` grant);
///  * watch the viewfinder: [VrxCameraView], a Flutter external texture the
///    flutter-vrx `vrx/camera` plugin fills from the channel
///    `camerad.frames`. The plugin opens that channel itself (a raw
///    descriptor cannot cross Dart's ResourceHandle) and gives each buffer
///    back when the engine is done with it.
///
/// Nothing here polls: the state arrives as file events, the photos as
/// replies, the frames as texture updates.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'channel.dart';
import 'theme.dart';

/// One camera camerad lists.
@immutable
class CameraInfo {
  const CameraInfo(
      {required this.id,
      required this.kind,
      required this.name,
      this.location = 'external',
      this.width = 0,
      this.height = 0});

  factory CameraInfo.fromJson(Map<String, dynamic> j) {
    final max = j['max'];
    return CameraInfo(
      id: '${j['id'] ?? ''}',
      kind: '${j['kind'] ?? ''}',
      name: '${j['name'] ?? ''}',
      location: '${j['location'] ?? 'external'}',
      width: max is List && max.length == 2 ? (max[0] as num).toInt() : 0,
      height: max is List && max.length == 2 ? (max[1] as num).toInt() : 0,
    );
  }

  final String id;

  /// `csi`, `usb` or `virtual`.
  final String kind;
  final String name;

  /// `front`, `back` or `external`.
  final String location;

  /// The largest picture it makes; 0 when it did not say.
  final int width, height;

  @override
  bool operator ==(Object other) =>
      other is CameraInfo &&
      other.id == id &&
      other.kind == kind &&
      other.name == name &&
      other.location == location &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(id, kind, name, location, width, height);
}

/// camerad's state file, parsed (plan 0018 D6).
@immutable
class CameraState {
  const CameraState({
    this.known = false,
    this.enabled = true,
    this.cameras = const [],
    this.active = false,
    this.clients = 0,
    this.reason = '',
  });

  /// camerad's file, or nothing: it is not running, so no camera.
  static const absent = CameraState();

  /// Read the file's text; anything that is not the documented shape is
  /// [absent], never an exception (a half-understood file shows nothing
  /// rather than a camera that is not there).
  factory CameraState.parse(String text) {
    try {
      final j = jsonDecode(text);
      if (j is! Map<String, dynamic>) return absent;
      final list = j['cameras'];
      return CameraState(
        known: true,
        enabled: j['enabled'] != false,
        cameras: [
          if (list is List)
            for (final c in list)
              if (c is Map<String, dynamic>) CameraInfo.fromJson(c),
        ],
        active: j['active'] == true,
        clients: (j['clients'] as num?)?.toInt() ?? 0,
        reason: '${j['reason'] ?? ''}',
      );
    } on FormatException {
      return absent;
    } on TypeError {
      return absent;
    }
  }

  /// The file exists: camerad is (or was this boot) running.
  final bool known;

  /// Settings > Camera is On.
  final bool enabled;
  final List<CameraInfo> cameras;

  /// A camera is running now (the strip's mark): true whoever started it.
  final bool active;
  final int clients;

  /// `ok`, `none-found`, `disabled`, `expected-csi-missing`, `starting`,
  /// `failed`, or empty when there is no file.
  final String reason;

  @override
  bool operator ==(Object other) =>
      other is CameraState &&
      other.known == known &&
      other.enabled == enabled &&
      listEquals(other.cameras, cameras) &&
      other.active == active &&
      other.clients == clients &&
      other.reason == reason;

  @override
  int get hashCode => Object.hash(known, enabled, Object.hashAll(cameras), active, clients, reason);
}

/// Watches camerad's state file. The directory is camerad's
/// RuntimeDirectory, removed when its unit stops, so a watch on the file
/// would be lost with it; this one watches the directory while it exists
/// and its parent while it does not.
class CameraService {
  CameraService({this.dir = '/run/vrx/camera', this.name = 'state.json'});

  /// The service the kit's widgets and applets share.
  static CameraService instance = CameraService();

  final String dir;
  final String name;

  Future<CameraState> read() async {
    try {
      return CameraState.parse(await File('$dir/$name').readAsString());
    } on FileSystemException {
      return CameraState.absent;
    }
  }

  /// The state now, and again whenever it changes (a repeat is not
  /// said twice).
  Stream<CameraState> watch() {
    StreamSubscription<FileSystemEvent>? events;
    CameraState? last;
    late final StreamController<CameraState> out;
    // publishes are SEQUENCED (CON-07, review 2026-10-17): concurrent
    // publishes raced an older read past a newer one, and the stale one
    // was shown as current. One in flight; the next coalesces after it.
    Future<void>? publishing;
    var closed = false;
    Future<void> publish() async {
      while (publishing != null) {
        try {
          await publishing;
        } on Object {
          break; // the previous read failed; ours goes now
        }
      }
      if (closed) return;
      final mine = () async {
        final now = await read();
        if (closed || out.isClosed || now == last) return;
        last = now;
        out.add(now);
      }();
      publishing = mine;
      await mine;
      if (identical(publishing, mine)) publishing = null;
    }

    Future<void> attach() async {
      if (closed) return; // add-after-close (CON-07): a closed stream adds nothing
      await events?.cancel();
      events = null;
      await publish();
      if (closed || out.isClosed) return;
      if (out.isClosed) return;
      final here = Directory(dir);
      final parent = here.parent;
      final target = await here.exists() ? here : parent;
      if (!await target.exists() || out.isClosed) return;
      events = target.watch().listen((ev) async {
        final names = [ev.path, if (ev is FileSystemMoveEvent) ev.destination ?? ''];
        if (target == here) {
          if (names.any((p) => p.endsWith('/$name'))) await publish();
          // the directory itself went: camerad stopped, watch for its return
          if (ev is FileSystemDeleteEvent && ev.path == here.path) await attach();
        } else if (names.any((p) => p == here.path)) {
          await attach();
        }
      }, onError: (Object _) {});
    }

    out = StreamController(
      onListen: attach,
      onCancel: () async {
        closed = true; // a late watcher event publishes nothing (CON-07)
        await events?.cancel();
        await out.close();
      },
    );
    return out.stream;
  }

  /// A camera is running (any client, any process): the strip's mark.
  Stream<bool> get active => watch().map((s) => s.active).distinct();

  /// The cameras camerad lists.
  Stream<List<CameraInfo>> get cameras => watch().map((s) => s.cameras).distinct(listEquals);

  /// Why there is no camera, or `ok`.
  Stream<String> get reason => watch().map((s) => s.reason).distinct();
}

/// What went wrong with a camera call, as camerad or the plugin named it.
class CameraError implements Exception {
  const CameraError(this.code, [this.message = '']);

  /// camerad's `no-camera|busy|disabled|no-room|folder-full|too-large|
  /// failed`, or the plugin's `busy|unavailable|not-permitted|failed|...`.
  final String code;
  final String message;

  @override
  String toString() => 'CameraError($code${message.isEmpty ? '' : ': $message'})';
}

/// A photo camerad took.
@immutable
class CameraShot {
  const CameraShot({required this.bytes, required this.width, required this.height, required this.path});

  final int bytes;
  final int width, height;

  /// The file's name in the photo folder (`IMG_0042.JPG`), or null when
  /// the request did not keep one.
  final String? path;
}

/// The `camerad.photos` channel (plan 0018 D7): requests and replies, one
/// JSON record each, matched by `id`. This client never asks for the
/// picture's descriptor (`fd: false`): it keeps the file and names it.
class CameraPhotos {
  CameraPhotos({Future<VrxChannel> Function()? open}) : _open = open ?? (() => VrxBridge.open('camerad', 'photos'));

  final Future<VrxChannel> Function() _open;
  VrxChannel? _channel;
  StreamSubscription<Object?>? _records;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  int _next = 0;

  /// How long a request waits before it counts as failed: a still of 8 MP
  /// on a Pi takes a few seconds, a camerad that hung is killed by its
  /// watchdog.
  static const patience = Duration(seconds: 20);

  // one open in flight (CON-07, review 2026-10-17): two first asks each
  // ran _ensure and opened TWO channels; whichever lost leaked.
  Future<void>? opening;
  Future<void> _ensure() async {
    if (_channel != null) return;
    final Future<void> mine = opening ??= () async {
      try {
        final channel = await _open();
        _channel = channel;
        _records = channel.records.listen(
          (record) {
            if (record is! Map<String, dynamic>) return;
            final done = _pending.remove((record['id'] as num?)?.toInt());
            done?.complete(record);
          },
          onError: (Object _) {
            _lost();
          },
          onDone: _lost,
        );
      } on Object catch (err) {
        throw CameraError('unavailable', '$err');
      } finally {
        opening = null;
      }
    }();
    await mine;
  }

  void _lost() {
    _channel = null;
    unawaited(_records?.cancel());
    _records = null;
    final all = [..._pending.values];
    _pending.clear();
    for (final c in all) {
      c.complete({'ok': false, 'error': 'failed'});
    }
  }

  Future<Map<String, dynamic>> _ask(Map<String, Object?> request) async {
    await _ensure();
    final id = ++_next;
    final done = Completer<Map<String, dynamic>>();
    _pending[id] = done;
    _channel!.write({...request, 'id': id});
    final reply = await done.future.timeout(patience, onTimeout: () {
      _pending.remove(id);
      return {'ok': false, 'error': 'failed'};
    });
    if (reply['ok'] != true) throw CameraError('${reply['error'] ?? 'failed'}');
    return reply;
  }

  /// Take a photo and keep it in the photo folder.
  Future<CameraShot> capture({String? camera, int? width, int quality = 85}) async {
    final r =
        await _ask({'op': 'capture', 'camera': camera, 'width': width, 'quality': quality, 'keep': true, 'fd': false});
    return CameraShot(
      bytes: (r['bytes'] as num?)?.toInt() ?? 0,
      width: (r['width'] as num?)?.toInt() ?? 0,
      height: (r['height'] as num?)?.toInt() ?? 0,
      path: r['path'] as String?,
    );
  }

  /// The cameras, as camerad lists them now.
  Future<List<CameraInfo>> list() async {
    final r = await _ask({'op': 'list'});
    final cameras = r['cameras'];
    return [
      if (cameras is List)
        for (final c in cameras)
          if (c is Map<String, dynamic>) CameraInfo.fromJson(c),
    ];
  }

  /// Choose which camera the viewfinder (and a capture that names none)
  /// uses; camerad answers `failed` for one it does not list.
  Future<void> select(String camera) => _ask({'op': 'select', 'camera': camera});

  /// Let go of the channel (the applet left).
  void close() {
    final channel = _channel;
    _channel = null;
    unawaited(_records?.cancel());
    _records = null;
    final all = [..._pending.values];
    _pending.clear();
    for (final c in all) {
      c.complete({'ok': false, 'error': 'failed'});
    }
    unawaited(channel?.socket.close());
  }
}

/// A viewfinder the plugin opened: the texture and its picture's shape.
@immutable
class CameraStream {
  const CameraStream({required this.textureId, required this.width, required this.height, this.copy = false});

  final int textureId;
  final int width, height;

  /// The plugin fell back to copying each frame (its EGL import was
  /// refused); the picture is the same, the cost is one copy.
  final bool copy;
}

/// The plugin's end of the viewfinder; a fake in tests.
abstract interface class CameraTexture {
  /// Open `camerad.frames` and make a texture of it. Throws a
  /// [CameraError] naming why not.
  Future<CameraStream> open();

  /// Release the texture and the channel.
  Future<void> close(int textureId);

  /// The plugin ended a stream on its own (camerad closed it: the camera
  /// was unplugged, or the camera went off), with its reason.
  Stream<({int textureId, String reason})> get ended;
}

/// flutter-vrx's `vrx/camera` platform channel: `open` answers
/// `{textureId, width, height, fourcc, buffers, mode: dmabuf|copy,
/// copyReason}` or an error code (`busy`, `unavailable`, `not-permitted`,
/// `not-declared`, `disabled`, `bad-offer`, `failed`); `close` takes
/// `{textureId}`; the plugin calls `closed {textureId, reason}` when the
/// producer ends the stream.
class PluginCameraTexture implements CameraTexture {
  PluginCameraTexture([MethodChannel? channel]) : _channel = channel ?? const MethodChannel('vrx/camera') {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'closed') return;
      final a = call.arguments;
      if (a is Map) _ended.add((textureId: (a['textureId'] as num?)?.toInt() ?? -1, reason: '${a['reason'] ?? ''}'));
    });
  }

  final MethodChannel _channel;
  final _ended = StreamController<({int textureId, String reason})>.broadcast();

  @override
  Stream<({int textureId, String reason})> get ended => _ended.stream;

  @override
  Future<CameraStream> open() async {
    try {
      final r = await _channel.invokeMapMethod<String, Object?>('open');
      if (r == null) throw const CameraError('failed', 'the plugin answered nothing');
      return CameraStream(
        textureId: (r['textureId'] as num).toInt(),
        width: (r['width'] as num).toInt(),
        height: (r['height'] as num).toInt(),
        copy: r['mode'] == 'copy',
      );
    } on PlatformException catch (e) {
      throw CameraError(e.code, e.message ?? '');
    } on MissingPluginException {
      throw const CameraError('unavailable', 'this build has no camera plugin');
    }
  }

  @override
  Future<void> close(int textureId) async {
    try {
      await _channel.invokeMethod<void>('close', {'textureId': textureId});
    } on PlatformException catch (e) {
      debugPrint('vrx camera: close: ${e.code}');
    } on MissingPluginException {
      // nothing was opened
    }
  }
}

/// The texture the kit's widgets use; tests install a fake.
abstract final class VrxCamera {
  static CameraTexture? _texture;

  static CameraTexture get texture => _texture ??= PluginCameraTexture();

  static void install(CameraTexture texture) => _texture = texture;
}

/// The viewfinder: camerad's frames as a texture, 4:3 unless the stream
/// says otherwise. It opens the stream when it is mounted and closes it
/// when it is disposed, so leaving the screen (or the applet) releases the
/// camera: camerad stops the sensor two seconds after its last viewer
/// (plan 0018 D12). A refused open, or a stream camerad ended, is reported
/// once through [onFailed] and [onEnded]; the owner decides what to show.
class VrxCameraView extends StatefulWidget {
  /// [BoxFit.contain] letterboxes the stream (the historic behavior); 
  /// [BoxFit.cover] fills the box and clips the overflow, the phone-camera 
  /// shape a full-bleed viewfinder wants.
  const VrxCameraView({super.key, this.texture, this.fit = BoxFit.contain, this.onStarted, this.onFailed, this.onEnded});

  /// The plugin (default [VrxCamera.texture]).
  final CameraTexture? texture;

  /// How the stream sits in the box the parent gives.
  final BoxFit fit;
  final void Function(CameraStream stream)? onStarted;
  final void Function(CameraError error)? onFailed;
  final void Function(String reason)? onEnded;

  @override
  State<VrxCameraView> createState() => _VrxCameraViewState();
}

class _VrxCameraViewState extends State<VrxCameraView> {
  CameraStream? _stream;
  StreamSubscription<({int textureId, String reason})>? _ended;
  bool _disposed = false;

  CameraTexture get _texture => widget.texture ?? VrxCamera.texture;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    final texture = _texture;
    try {
      final stream = await texture.open();
      if (_disposed) {
        // left before the plugin answered: give it straight back
        unawaited(texture.close(stream.textureId));
        return;
      }
      _ended = texture.ended.listen((e) {
        if (e.textureId == stream.textureId && !_disposed) {
          setState(() => _stream = null);
          widget.onEnded?.call(e.reason);
        }
      });
      setState(() => _stream = stream);
      widget.onStarted?.call(stream);
    } on CameraError catch (err) {
      if (!_disposed) widget.onFailed?.call(err);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_ended?.cancel());
    final id = _stream?.textureId;
    if (id != null) unawaited(_texture.close(id));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = VrxTheme.of(context);
    final s = _stream;
    final picture = AspectRatio(
      aspectRatio: s == null || s.height == 0 ? 4 / 3 : s.width / s.height,
      child: Semantics(
        label: 'Camera viewfinder',
        image: true,
        child: ColoredBox(color: colors.surfaceHigh, child: s == null ? null : Texture(textureId: s.textureId)),
      ),
    );
    if (widget.fit == BoxFit.contain) {
      return picture;
    }
    // cover: the picture keeps its ratio and fills the box, the overflow
    // clipped. Computed here because FittedBox hands its child unbounded
    // constraints and AspectRatio needs a bounded one.
    final ratio = s == null || s.height == 0 ? 4 / 3 : s.width / s.height;
    return LayoutBuilder(builder: (context, box) {
      var w = box.maxWidth;
      var h = w / ratio;
      if (h < box.maxHeight) {
        h = box.maxHeight;
        w = h * ratio;
      }
      return ClipRect(
        child: Center(
          child: SizedBox(width: w, height: h, child: picture),
        ),
      );
    });
  }
}
