import 'package:vrx_kit/vrx_kit.dart';

/// Everything settings reacts to.
enum SettingsAction {
  init,
  categoryOpened,
  changed,
  resetAll,
}

/// One settings row: what the UI renders for a declared setting.
class SettingsRow {
  const SettingsRow({
    required this.key,
    required this.label,
    required this.category,
    required this.value,
    required this.options,
  });

  final String key;
  final String label;
  final String category;
  final String value;
  final List<String> options;
}

/// What settings draws.
class SettingsView {
  const SettingsView({required this.rows, required this.openCategory});

  /// The visible rows, in declaration order.
  final List<SettingsRow> rows;

  /// The open category (null: the category list).
  final String? openCategory;
}

/// The settings model. Declared settings come from the applet
/// manifests (the registry feeds them in); values live in
/// `/data/settings` — a file per key, the state IPC shape, watched by
/// everyone who cares.
class SettingsModel
    extends StoreModel<SettingsState, SettingsAction, SettingsView> {
  SettingsModel({Map<String, String> declared = const {
    'clock_format': '24h',
    'theme': 'dark',
  }})
      : _declared = {
          'clock_format': ('Time format', 'Clock', ['12h', '24h']),
          'theme': ('Theme', 'Appearance', ['dark', 'light']),
        },
        _values = Map.of(declared),
        _openCategory = null {
    assert(_declared.keys.toSet().containsAll(_values.keys));
  }

  final Map<String, (String, String, List<String>)> _declared;
  final Map<String, String> _values;
  String? _openCategory;

  @override
  SettingsState get initial =>
      SettingsState(values: Map.of(_values), openCategory: _openCategory);

  @override
  SettingsAction get bootAction => SettingsAction.init;

  @override
  SettingsView reduce(SettingsState state, SettingsAction action) {
    switch (action) {
      case SettingsAction.init:
        break;
      case SettingsAction.categoryOpened:
        break; // opened through the nav intent, not a model change
      case SettingsAction.changed:
        break;
      case SettingsAction.resetAll:
        for (final key in _values.keys.toList()) {
          _values[key] = _declared[key]?.$3.last ?? _values[key]!;
        }
    }
    return SettingsView(rows: _rows(), openCategory: _openCategory);
  }

  /// A setting changed: apply it, derive the view. This is the action
  /// the settings store's file-watcher dispatches when another applet
  /// or the host writes a value.
  void changeValue(String key, String value) {
    if (_declared.containsKey(key)) {
      _values[key] = value;
    }
  }

  void openCategory(String category) => _openCategory = category;

  List<SettingsRow> _rows() {
    final rows = <SettingsRow>[];
    for (final entry in _declared.entries) {
      if (_openCategory != null && entry.value.$2 != _openCategory) continue;
      rows.add(SettingsRow(
        key: entry.key,
        label: entry.value.$1,
        category: entry.value.$2,
        value: _values[entry.key] ?? entry.value.$3.first,
        options: entry.value.$3,
      ));
    }
    return rows;
  }

  @override
  SettingsState get snapshot =>
      SettingsState(values: Map.of(_values), openCategory: _openCategory);
}

/// The settings state snapshot: the values (what /data/settings
/// holds) and where the user was.
class SettingsState {
  const SettingsState({required this.values, required this.openCategory});

  final Map<String, String> values;
  final String? openCategory;
}
