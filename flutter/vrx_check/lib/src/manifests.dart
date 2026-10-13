/// The repo's applet manifests, read for the layout check: every applet's
/// name and icon (as Home shows them) and every declared setting (as
/// Settings shows it), so a new applet's strings are measured on every
/// display without anyone writing a test for them. A reader for the keys
/// the check needs, not a TOML parser: vrxhost's parser is the one that
/// decides what a manifest means.
library;

import 'dart:io';

class ManifestSetting {
  const ManifestSetting(this.key, this.label, this.type, this.defaultValue, this.options);

  final String key, label, type, defaultValue;
  final List<String> options;
}

class ManifestFacts {
  ManifestFacts(this.id, this.name, this.icon, this.tile, this.position, this.settings);

  final String id, name, icon;
  final bool tile;
  final int position;
  final List<ManifestSetting> settings;
}

Object? _value(String raw) {
  final v = raw.trim();
  if (v.startsWith('"')) return v.substring(1, v.indexOf('"', 1));
  if (v.startsWith('[')) {
    return RegExp(r'"([^"]*)"').allMatches(v).map((m) => m[1]!).toList();
  }
  if (v == 'true' || v == 'false') return v == 'true';
  return num.tryParse(v.split(RegExp(r'\s')).first);
}

ManifestFacts parseManifestFacts(String text) {
  var section = '';
  final top = <String, Object?>{};
  final display = <String, Object?>{};
  final settings = <Map<String, Object?>>[];
  for (final raw in text.split('\n')) {
    // a # outside a string starts a comment
    var line = raw;
    final hash = RegExp(r'#(?=(?:[^"]*"[^"]*")*[^"]*$)').firstMatch(line);
    if (hash != null) line = line.substring(0, hash.start);
    line = line.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('[[')) {
      section = line.replaceAll(RegExp(r'[\[\]\s]'), '');
      if (section == 'applet.settings') settings.add({});
      continue;
    }
    if (line.startsWith('[')) {
      section = line.replaceAll(RegExp(r'[\[\]\s]'), '');
      continue;
    }
    final eq = line.indexOf('=');
    if (eq < 0) continue;
    final k = line.substring(0, eq).trim(), v = _value(line.substring(eq + 1));
    switch (section) {
      case 'applet':
        top[k] = v;
      case 'applet.display':
        display[k] = v;
      case 'applet.settings':
        settings.last[k] = v;
    }
  }
  String str(Object? o) => o == null ? '' : '$o';
  return ManifestFacts(
    str(top['id']),
    str(top['name']),
    str(display['icon']),
    display['tile'] == true,
    (display['position'] as num?)?.toInt() ?? 0,
    [
      for (final s in settings)
        ManifestSetting(str(s['key']), str(s['label']), str(s['type']), str(s['default']), [for (final o in (s['options'] as List? ?? const [])) '$o']),
    ],
  );
}

/// Every applets/*/manifest.toml in the repo, by id. [repo] defaults to
/// two levels up from an applet's directory (where its tests run).
List<ManifestFacts> repoManifests({String repo = '../..'}) {
  final dir = Directory('$repo/applets');
  final out = <ManifestFacts>[
    // vrx-allow: test-time setup, not an applet's event loop
    for (final d in dir.listSync().whereType<Directory>())
      // vrx-allow: test-time setup
      if (File('${d.path}/manifest.toml').existsSync())
        // vrx-allow: test-time setup
        parseManifestFacts(File('${d.path}/manifest.toml').readAsStringSync()),
  ]..sort((a, b) => a.id.compareTo(b.id));
  return out;
}
