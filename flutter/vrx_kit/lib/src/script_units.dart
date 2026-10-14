part of 'system.dart';

/// Background scripts (plan 0013 D13): each is an instance of systemd's
/// `vrx-script@.service`, a template the layer ships with the applet
/// sandbox and a fixed ExecStart (python3 on the script in the Scripts
/// folder). The Scripts applet's `scripts` grant lets it start, stop and
/// clear those instances and no other unit; systemd supervises, restarts
/// on a crash, gives up after its start limit, and the restart count is
/// how a script is seen to be failing.
abstract class ScriptUnitsService {
  /// The background scripts systemd knows: running, restarting, or
  /// stopped after failing.
  Future<List<ScriptUnit>> list();

  /// [list] now and again whenever systemd says a unit or job changed.
  Stream<List<ScriptUnit>> watch();

  /// Start [script] (a file name in the Scripts folder) in the background.
  Future<void> start(String script);

  /// Stop it; a script stopped after failing is cleared instead.
  Future<void> stop(String script);
}

/// How a background script is doing, as systemd sees it.
enum ScriptUnitState {
  /// Starting, or running with no restart.
  running,

  /// Running or about to restart, having crashed [ScriptUnit.restarts]
  /// times.
  failing,

  /// Stopped by systemd after crashing past its start limit.
  failed,
}

class ScriptUnit {
  const ScriptUnit({required this.script, required this.state, this.restarts = 0});

  /// The script's file name (`blink.py`).
  final String script;
  final ScriptUnitState state;
  final int restarts;

  /// The unit's instance name for [script], or null when the name can
  /// not be one: only letters, digits, `-` and `_` before `.py`, so the
  /// instance needs no escaping and names exactly that file.
  static String? instanceFor(String script) {
    if (!script.endsWith('.py')) return null;
    final base = script.substring(0, script.length - 3);
    return RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(base) ? base : null;
  }

  @override
  bool operator ==(Object other) =>
      other is ScriptUnit && other.script == script && other.state == state && other.restarts == restarts;

  @override
  int get hashCode => Object.hash(script, state, restarts);
}

class SystemdScriptUnits implements ScriptUnitsService {
  SystemdScriptUnits(this.bus)
      : _manager = DBusRemoteObject(bus,
            name: 'org.freedesktop.systemd1', path: DBusObjectPath('/org/freedesktop/systemd1'));

  final DBusClient bus;
  final DBusRemoteObject _manager;
  static const _managerIface = 'org.freedesktop.systemd1.Manager';
  static const _prefix = 'vrx-script@';
  static const _suffix = '.service';

  static String _unit(String script) {
    final instance = ScriptUnit.instanceFor(script);
    if (instance == null) {
      throw const SystemError('vrx.ScriptName', 'only a script named with letters, digits, - and _ runs in the background');
    }
    return '$_prefix$instance$_suffix';
  }

  @override
  Future<List<ScriptUnit>> list() => _call(() async {
        final reply = await _manager.callMethod(
          _managerIface,
          'ListUnitsByPatterns',
          [
            DBusArray.string(const ['active', 'activating', 'deactivating', 'failed']),
            DBusArray.string(const ['$_prefix*$_suffix']),
          ],
          replySignature: DBusSignature('a(ssssssouso)'),
        );
        final units = <ScriptUnit>[];
        for (final entry in reply.returnValues.first.asArray()) {
          final f = entry.asStruct();
          final name = f[0].asString();
          final active = f[3].asString();
          final sub = f[4].asString();
          final script = '${name.substring(_prefix.length, name.length - _suffix.length)}.py';
          var restarts = 0;
          try {
            final unit = DBusRemoteObject(bus, name: 'org.freedesktop.systemd1', path: f[6].asObjectPath());
            restarts = (await unit.getProperty('org.freedesktop.systemd1.Service', 'NRestarts')).asUint32();
          } on DBusMethodResponseException {
            // a unit gone between the list and the read: no count
          }
          final state = active == 'failed'
              ? ScriptUnitState.failed
              : (restarts > 0 || sub == 'auto-restart')
                  ? ScriptUnitState.failing
                  : ScriptUnitState.running;
          units.add(ScriptUnit(script: script, state: state, restarts: restarts));
        }
        units.sort((a, b) => a.script.compareTo(b.script));
        return units;
      });

  @override
  Stream<List<ScriptUnit>> watch() {
    late StreamController<List<ScriptUnit>> out;
    final subscriptions = <StreamSubscription<Object?>>[];
    var last = const <ScriptUnit>[];
    Future<void> read() async {
      try {
        final now = await list();
        if (!_same(now, last)) out.add(last = now);
      } on Object catch (err) {
        out.addError(err);
      }
    }

    out = StreamController<List<ScriptUnit>>(
      onListen: () {
        // systemd sends unit and job signals to a client that subscribed
        unawaited(() async {
          try {
            await _manager.callMethod(_managerIface, 'Subscribe', const []);
          } on DBusMethodResponseException {
            // already subscribed by this connection, or systemd refused:
            // the signals then come from another subscriber, or not at all
          }
        }());
        subscriptions
          ..add(DBusSignalStream(bus,
                  sender: 'org.freedesktop.systemd1', interface: _managerIface, name: 'JobRemoved')
              .listen((s) {
            if (s.values.length > 2 && s.values[2].asString().startsWith(_prefix)) unawaited(read());
          }))
          ..add(DBusSignalStream(bus,
                  sender: 'org.freedesktop.systemd1', interface: _managerIface, name: 'UnitRemoved')
              .listen((s) {
            if (s.values.isNotEmpty && s.values.first.asString().startsWith(_prefix)) unawaited(read());
          }))
          // a crash and its restart change the unit's properties
          ..add(DBusSignalStream(bus,
                  sender: 'org.freedesktop.systemd1',
                  interface: 'org.freedesktop.DBus.Properties',
                  name: 'PropertiesChanged',
                  pathNamespace: DBusObjectPath('/org/freedesktop/systemd1/unit'))
              .listen((s) {
            if (s.path.value.startsWith('/org/freedesktop/systemd1/unit/vrx_2dscript_40')) unawaited(read());
          }));
        unawaited(read());
      },
      onCancel: () async {
        for (final s in subscriptions) {
          await s.cancel();
        }
        await out.close();
      },
    );
    return out.stream;
  }

  static bool _same(List<ScriptUnit> a, List<ScriptUnit> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  Future<void> start(String script) async {
    final unit = _Unit(bus, _unit(script));
    // a script stopped after failing must be cleared before it starts again
    try {
      await _manager.callMethod(_managerIface, 'ResetFailedUnit', [DBusString(unit.name)]);
    } on DBusMethodResponseException {
      // not loaded, or not failed: nothing to clear
    }
    await unit.run(true);
  }

  @override
  Future<void> stop(String script) async {
    final name = _unit(script);
    final failed = (await list()).any((u) => u.script == script && u.state == ScriptUnitState.failed);
    if (failed) {
      await _call(() => _manager.callMethod(_managerIface, 'ResetFailedUnit', [DBusString(name)]));
    } else {
      await _Unit(bus, name).run(false);
    }
  }
}
