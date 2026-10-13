/// Applet settings (plan 0008 D5): one file per applet,
/// /etc/vrx/settings/ID.conf, `key=value` lines. Every applet reads its
/// own and is told when it changes (inotify, the state shape "a file,
/// watched"); the Settings applet, holding the settings grant (group
/// vrx-config), writes any.
/// What an applet may set is declared in its manifest; vrxhost serves the
/// declarations (io.vrx.Host.Settings).
library;

import 'dart:async';
import 'dart:io';

import 'file.dart';

/// Where the settings files live.
const settingsDir = '/etc/vrx/settings';

/// A setting an applet declares in its manifest.
class SettingDecl {
  const SettingDecl({
    required this.key,
    required this.label,
    required this.category,
    required this.type,
    required this.defaultValue,
    this.options = const [],
  });

  factory SettingDecl.fromJson(Map<String, dynamic> j) => SettingDecl(
        key: '${j['key']}',
        label: '${j['label']}',
        category: '${j['category'] ?? ''}',
        type: '${j['type']}',
        defaultValue: settingText(j['default']),
        options: [for (final o in (j['options'] as List? ?? const [])) '$o'],
      );

  final String key;
  final String label;
  final String category;

  /// enum, bool, int, float or text.
  final String type;
  final String defaultValue;
  final List<String> options;
}

/// One applet's declared settings.
class AppletSettingsDecl {
  const AppletSettingsDecl({required this.id, required this.name, required this.settings});

  final String id;
  final String name;
  final List<SettingDecl> settings;
}

/// A JSON default as it is written in a settings file.
String settingText(Object? v) => switch (v) {
      null => '',
      bool b => b ? 'true' : 'false',
      _ => '$v',
    };

/// key=value lines; blank lines and # comments skipped, the last of a
/// repeated key wins.
Map<String, String> parseSettings(String text) {
  final out = <String, String>{};
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final eq = line.indexOf('=');
    if (eq <= 0) continue;
    out[line.substring(0, eq).trim()] = line.substring(eq + 1).trim();
  }
  return out;
}

/// The file's text for [values], keys in order, a value never spanning a
/// line.
String formatSettings(String applet, Map<String, String> values) {
  final b = StringBuffer("# $applet's settings (its manifest's [[applet.settings]]); Settings writes this\n");
  for (final e in values.entries) {
    b.writeln('${e.key}=${e.value.replaceAll('\n', ' ')}');
  }
  return b.toString();
}

/// Read and write the settings files.
class AppletSettings {
  AppletSettings({this.dir = settingsDir});

  final String dir;

  File _file(String applet) => File('$dir/$applet.conf');

  Future<Map<String, String>> read(String applet) async {
    try {
      return parseSettings(await _file(applet).readAsString());
    } on FileSystemException {
      return const {};
    }
  }

  /// [applet]'s settings now, and again whenever its file changes.
  Stream<Map<String, String>> watch(String applet) => watchSettingsFile(dir, '$applet.conf', () => read(applet));

  /// Set one key (the settings grant): a new file renamed over the old,
  /// so a reader never sees half of one.
  Future<void> set(String applet, String key, String value) async {
    final values = Map.of(await read(applet))..[key] = value;
    await replaceSettingsFile(dir, '$applet.conf', formatSettings(applet, values));
  }
}

/// A key=value file in [dir] read now by [read], and again whenever it
/// changes. A controller, not an async* generator: cancelling a generator
/// parked in an await-for waits for the next file event.
Stream<Map<String, String>> watchSettingsFile(String dir, String name, Future<Map<String, String>> Function() read) {
  StreamSubscription<FileSystemEvent>? events;
  late final StreamController<Map<String, String>> out;
  out = StreamController(
    onListen: () async {
      out.add(await read());
      final d = Directory(dir);
      if (!await d.exists() || out.isClosed) return;
      // the directory, not the file: a write is a new file renamed over it
      events = d.watch().listen((ev) async {
        // a write is a rename: on Linux a move event whose path is the
        // temporary name and whose destination is the file
        final hit = ev.path.endsWith('/$name') || (ev is FileSystemMoveEvent && (ev.destination ?? '').endsWith('/$name'));
        if (hit && !out.isClosed) out.add(await read());
      });
    },
    onCancel: () async {
      await events?.cancel();
      await out.close();
    },
  );
  return out.stream;
}

/// Replace [dir]/[name] with [text]: a new file renamed over the old, so
/// a reader never sees half of one. The one way vrx writes a settings
/// file.
// readable by whoever reads it: 0664, the directory's group by setgid
Future<void> replaceSettingsFile(String dir, String name, String text) =>
    VrxFile.writeAtomic('$dir/$name', text, mode: '0664');
