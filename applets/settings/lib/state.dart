import 'package:vrx_kit/vrx_kit.dart';

/// Everything settings reacts to.
enum SettingsAction {
  init,

  /// A system fact changed (time, device, light, power): re-derive.
  factsChanged,

  /// A category was opened or closed, or the zone picker toggled.
  navigated,

  /// The zone list arrived.
  zonesLoaded,

  /// A system call failed; the banner says why.
  failed,
}

/// The settings categories, in the order evrx-rt's Settings lists them.
enum SettingsCategory { display, power, time, network, device, about }

/// What a row does when tapped.
enum RowKind {
  /// A reading; nothing happens.
  info,

  /// Opens something (the zone picker, another applet).
  open,

  /// A two-state switch.
  toggle,

  /// A destructive act behind a confirmation.
  confirm,
}

/// One rendered row.
class SettingRow {
  const SettingRow({
    required this.key,
    required this.label,
    required this.value,
    required this.kind,
    this.on = false,
  });

  final String key;
  final String label;
  final String value;
  final RowKind kind;

  /// A toggle's state.
  final bool on;
}

/// One category in the list.
class CategoryRow {
  const CategoryRow(this.category, this.label, this.glyph, this.summary);

  final SettingsCategory category;
  final String label;

  /// A VrxSymbols name.
  final String glyph;
  final String summary;
}

/// What settings draws.
class SettingsView {
  const SettingsView({
    required this.categories,
    required this.open,
    required this.rows,
    required this.zones,
    required this.pickingZone,
    required this.error,
  });

  final List<CategoryRow> categories;
  final SettingsCategory? open;
  final List<SettingRow> rows;
  final List<String> zones;
  final bool pickingZone;
  final String? error;
}

/// The settings model: the system's facts as its state, the rows derived
/// from them. Rows a device cannot offer are not offered (plan 0008 D12):
/// no Display without a backlight, no Power when this applet may not
/// power off. Applets' own declared settings join with plan 0008 D5.
class SettingsModel extends StoreModel<SettingsState, SettingsAction, SettingsView> {
  TimeState? time;
  NetworkState? network;
  DeviceState? device;
  bool? light;
  int lightLevels = 0;
  bool canPowerOff = false;
  SettingsCategory? open;
  bool pickingZone = false;
  List<String> zones = const [];
  String? error;

  @override
  SettingsState get initial => SettingsState(open: open, pickingZone: pickingZone);

  @override
  SettingsAction get bootAction => SettingsAction.init;

  @override
  SettingsView reduce(SettingsState state, SettingsAction action) {
    if (action == SettingsAction.navigated) error = null;
    return SettingsView(
      categories: _categories(),
      open: open,
      rows: open == null ? const [] : _rows(open!),
      zones: zones,
      pickingZone: pickingZone,
      error: error,
    );
  }

  List<CategoryRow> _categories() => [
        if (lightLevels > 0)
          CategoryRow(SettingsCategory.display, 'Display', 'brightness_6',
              light == true ? 'Light on' : 'Light off'),
        if (canPowerOff) const CategoryRow(SettingsCategory.power, 'Power', 'power_settings_new', ''),
        CategoryRow(SettingsCategory.time, 'Time', 'schedule', time?.zone ?? ''),
        CategoryRow(SettingsCategory.network, 'Network', 'wifi', network?.connected?.name ?? (network?.ethernet == 'online' || network?.ethernet == 'ready' ? 'Wired' : '')),
        CategoryRow(SettingsCategory.device, 'Device', 'developer_board', device?.name ?? ''),
        const CategoryRow(SettingsCategory.about, 'About', 'info', ''),
      ];

  List<SettingRow> _rows(SettingsCategory category) {
    switch (category) {
      case SettingsCategory.display:
        return [
          SettingRow(
            key: 'light',
            label: 'Light',
            value: light == true ? 'On' : 'Off',
            kind: RowKind.toggle,
            on: light == true,
          ),
        ];
      case SettingsCategory.power:
        return const [
          SettingRow(key: 'restart', label: 'Restart', value: '', kind: RowKind.confirm),
          SettingRow(key: 'power_off', label: 'Power off', value: '', kind: RowKind.confirm),
        ];
      case SettingsCategory.time:
        final t = time;
        return [
          SettingRow(key: 'zone', label: 'Time zone', value: t?.zone ?? '…', kind: RowKind.open),
          SettingRow(
            key: 'automatic',
            label: 'Network time',
            value: t == null ? '…' : (t.automatic ? 'On' : 'Off'),
            kind: RowKind.toggle,
            on: t?.automatic ?? false,
          ),
          SettingRow(
            key: 'synced',
            label: 'Clock',
            value: t == null ? '…' : (t.synced ? 'Synchronised' : 'Not synchronised'),
            kind: RowKind.info,
          ),
        ];
      case SettingsCategory.network:
        final n = network;
        return [
          if (n == null || n.wifiPresent)
            SettingRow(key: 'wifi', label: 'Wi-Fi', value: n?.connected?.name ?? (n?.wifiOn == true ? 'On' : 'Off'), kind: RowKind.open),
          SettingRow(
            key: 'ethernet',
            label: 'Wired',
            value: n == null || n.ethernet.isEmpty ? 'Not connected' : (n.ethernet == 'online' || n.ethernet == 'ready' ? 'Connected' : n.ethernet),
            kind: RowKind.info,
          ),
          SettingRow(key: 'address', label: 'Address', value: n?.address.isNotEmpty == true ? n!.address : '—', kind: RowKind.info),
        ];
      case SettingsCategory.device:
        final d = device;
        return [
          SettingRow(key: 'name', label: 'Name', value: d?.name ?? '…', kind: RowKind.info),
          SettingRow(key: 'hostname', label: 'Network name', value: d?.hostname ?? '…', kind: RowKind.info),
          const SettingRow(key: 'setup', label: 'Set up again', value: '', kind: RowKind.open),
        ];
      case SettingsCategory.about:
        final d = device;
        return [
          SettingRow(key: 'system', label: 'System', value: d?.system ?? '…', kind: RowKind.info),
          SettingRow(key: 'model', label: 'Hardware', value: d?.model ?? '…', kind: RowKind.info),
          const SettingRow(key: 'licences', label: 'Licences', value: '', kind: RowKind.open),
        ];
    }
  }

  @override
  SettingsState get snapshot => SettingsState(open: open, pickingZone: pickingZone);
}

/// What suspension keeps: where the person was.
class SettingsState {
  const SettingsState({required this.open, required this.pickingZone});

  final SettingsCategory? open;
  final bool pickingZone;
}
