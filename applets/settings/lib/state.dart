import 'package:vrx_kit/vrx_kit.dart';

/// Everything settings reacts to.
enum SettingsAction {
  init,

  /// A system fact changed (time, device, screen, power): re-derive.
  factsChanged,

  /// A category was opened or closed, or the zone picker toggled.
  navigated,

  /// The zone list arrived.
  zonesLoaded,

  /// The rename screen opened or closed.
  renaming,

  /// A system call failed; the banner says why.
  failed,
}

/// Which of the clock's wheels is up (Settings > Time, plan 0011 D14).
enum SettingTime { none, date, time }

/// The settings categories, in the order evrx-rt's Settings lists them.
enum SettingsCategory { display, power, time, network, device, applets }

/// What a row does when tapped.
enum RowKind {
  /// A reading; nothing happens.
  info,

  /// Opens something (the zone picker, another applet).
  open,

  /// A two-state switch, or a tap that steps through choices.
  toggle,

  /// A slider (the brightness); [SettingRow.level] is its position.
  slider,

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
    this.level = 0,
  });

  final String key;
  final String label;
  final String value;
  final RowKind kind;

  /// A toggle's state.
  final bool on;

  /// A slider's position, 0 to 100.
  final int level;
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
    required this.renaming,
    required this.error,
    this.timeLocales = const [],
    this.pickingTimeFormat = false,
    this.settingTime = SettingTime.none,
  });

  final List<CategoryRow> categories;

  /// The installed locales a time format can be chosen from.
  final List<TimeLocale> timeLocales;
  final bool pickingTimeFormat;
  final SettingTime settingTime;
  final SettingsCategory? open;
  final List<SettingRow> rows;
  final List<String> zones;
  final bool pickingZone;
  final bool renaming;
  final String? error;
}

/// The screen-off choices, in seconds (0 = never), and how each reads.
/// The compositor reads `light_off` from the screen's settings file
/// (/etc/vrx/display/screen.conf, plan 0010 D7); vrx-policy seeds it.
const lightOffChoices = [0, 30, 60, 120, 300, 600];

String lightOffLabel(int seconds) => switch (seconds) {
      0 => 'Never',
      < 60 => '$seconds s',
      _ => '${seconds ~/ 60} min',
    };

/// The settings model: the system's facts as its state, the rows derived
/// from them. Rows a device cannot offer are not offered (plan 0008 D12):
/// no Brightness where the screen does not dim, no Power when this applet
/// may not power off. Display is always there: Settings is on a screen.
/// Applets' own declared settings join with plan 0008 D5.
class SettingsModel extends StoreModel<SettingsState, SettingsAction, SettingsView> {
  TimeState? time;
  NetworkState? network;
  DeviceState? device;

  /// The screen's settings and how the compositor dims (plan 0010).
  ScreenState screen = const ScreenState();
  VrxDimming dimming = VrxDimming.none;
  bool canPowerOff = false;

  /// The board has a USB device port (a UDC): the USB row.
  bool usbPresent = false;

  /// The Bluetooth radio, the adapter and the paired phones (plan 0011
  /// D19); null until read, or on a device with none.
  BluetoothState? bluetooth;

  /// Device Link's row value: what Bluetooth is doing, in a few words.
  static String linkValue(BluetoothState b) {
    if (!b.on) return 'Off';
    if (b.discoverable) return 'Pairing';
    final c = b.connected;
    if (c != null) return c.name;
    if (b.devices.isEmpty) return 'On';
    return b.devices.length == 1 ? '1 paired' : '${b.devices.length} paired';
  }

  /// The supply is too low (null: the board has no supply sensor).
  bool? supplyLow;

  /// The battery, where the kernel reports one (plan 0011 D12).
  Battery? battery;

  /// Free memory and space (About).
  DeviceUsage usage = const DeviceUsage();

  /// What applets cost and why the device is awake (plan 0012 D12): the
  /// screens open, and what vrxhost said (null while it loads).
  bool energyAvailable = false;
  bool showingUse = false;
  bool showingAwake = false;
  EnergyReport? energy;
  AwakeReport? awake;

  /// The installed locales and the one LC_TIME is now (plan 0011 D7).
  List<TimeLocale> timeLocales = const [];
  String timeLocale = '';
  bool pickingTimeFormat = false;
  SettingTime settingTime = SettingTime.none;
  /// Applets' declared settings (vrxhost) and their values (the files).
  List<AppletSettingsDecl> declared = const [];
  final values = <String, Map<String, String>>{};

  /// A text or number setting being typed: (applet, key).
  (String, String)? editingSetting;
  SettingsCategory? open;
  bool pickingZone = false;
  bool renaming = false;
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
      renaming: renaming,
      error: error,
      timeLocales: timeLocales,
      pickingTimeFormat: pickingTimeFormat,
      settingTime: settingTime,
    );
  }

  /// The time locale now, with its example, or null when unknown.
  TimeLocale? get currentTimeLocale {
    for (final l in timeLocales) {
      if (l.name == timeLocale) return l;
    }
    return null;
  }

  /// Setting the clock by hand is offered while network time is off or
  /// has not synchronised (timedated refuses SetTime while NTP is on, and
  /// says so through the words table).
  bool get canSetTime => time != null && (!time!.automatic || !time!.synced);

  List<CategoryRow> _categories() => [
        CategoryRow(SettingsCategory.display, 'Display', 'brightness_6', _screenOffText),
        if (canPowerOff || supplyLow != null || battery != null || energyAvailable)
          CategoryRow(SettingsCategory.power, 'Power', 'power_settings_new',
              supplyLow == true ? 'Supply too low' : (battery?.percent != null ? '${battery!.percent} %' : '')),
        CategoryRow(SettingsCategory.time, 'Time', 'schedule', time?.zone ?? ''),
        CategoryRow(SettingsCategory.network, 'Network', 'wifi', network?.connected?.name ?? (network?.ethernet == 'online' || network?.ethernet == 'ready' ? 'Wired' : '')),
        CategoryRow(SettingsCategory.device, 'Device', 'developer_board', device?.name ?? ''),
        // what applets let the person set (plan 0008 D5), when any do
        if (declared.isNotEmpty) const CategoryRow(SettingsCategory.applets, 'Applets', 'apps', ''),
      ];

  /// The scheme this boot draws (0: a grey panel, which offers none) and
  /// its polarity, from the kit at start; the chosen ones are the system
  /// settings file's, shown here and drawn after a restart (plan 0009 D9).
  int runningScheme = 0;
  bool runningDark = true;
  int get chosenScheme {
    final n = int.tryParse(values['vrx']?['scheme'] ?? '');
    return n != null && n >= 1 && n <= VrxColors.schemeCount ? n : runningScheme;
  }

  bool get chosenDark => switch (values['vrx']?['polarity']) {
        'light' => false,
        'dark' => true,
        _ => runningDark,
      };

  /// The look chosen differs from the one drawn: a restart applies it.
  bool get lookPending => runningScheme > 0 && (chosenScheme != runningScheme || chosenDark != runningDark);

  bool pickingScheme = false;

  /// The screen-off timeout now.
  int get lightOff => screen.lightOff;

  String get _screenOffText => lightOff == 0 ? 'Stays on' : 'Off after ${lightOffLabel(lightOff)}';

  /// What a tap on the light-off row sets: the next choice.
  int get nextLightOff {
    final i = lightOffChoices.indexOf(lightOff);
    return lightOffChoices[(i + 1) % lightOffChoices.length];
  }

  /// A setting's value now: its file's, else its declared default.
  String valueOf(String applet, SettingDecl decl) => values[applet]?[decl.key] ?? decl.defaultValue;

  /// What a tap on an enum or bool setting sets: the next option.
  String nextValue(String applet, SettingDecl decl) {
    final now = valueOf(applet, decl);
    if (decl.type == 'bool') return now == 'true' ? 'false' : 'true';
    if (decl.options.isEmpty) return now;
    final i = decl.options.indexOf(now);
    return decl.options[(i + 1) % decl.options.length];
  }

  SettingDecl? declOf(String applet, String key) {
    for (final a in declared) {
      if (a.id != applet) continue;
      for (final s in a.settings) {
        if (s.key == key) return s;
      }
    }
    return null;
  }

  List<SettingRow> _rows(SettingsCategory category) {
    switch (category) {
      case SettingsCategory.display:
        return [
          // no light switch: the screen is never made dark by hand, only
          // dimmed to the compositor's floor (plan 0010 D1, D8)
          if (dimming != VrxDimming.none)
            SettingRow(
              key: 'brightness',
              label: 'Brightness',
              value: '${screen.brightness}',
              kind: RowKind.slider,
              level: screen.brightness,
            ),
          // a tap steps through the choices; the compositor watches the file
          SettingRow(
            key: 'light_off',
            label: 'Screen off after',
            value: lightOffLabel(lightOff),
            kind: RowKind.toggle,
          ),
          // the scheme, on a panel that draws one; it changes at the next boot
          if (runningScheme > 0) ...[
            SettingRow(key: 'scheme', label: 'Colour scheme', value: VrxColors.schemeName(chosenScheme), kind: RowKind.open),
            SettingRow(
              key: 'polarity',
              label: 'Dark',
              value: chosenDark ? 'On' : 'Off',
              kind: RowKind.toggle,
              on: chosenDark,
            ),
            if (lookPending)
              const SettingRow(key: 'restart', label: 'Restart to apply', value: '', kind: RowKind.confirm),
          ],
        ];
      case SettingsCategory.power:
        final b = battery;
        return [
          if (b != null) ...[
            SettingRow(
              key: 'battery',
              label: 'Battery',
              value: [
                if (b.percent != null) '${b.percent} %',
                if (b.charging) 'charging' else if (b.full) 'full',
              ].join(', '),
              kind: RowKind.info,
            ),
            if (b.volts != null)
              SettingRow(key: 'battery_volts', label: 'Battery voltage', value: '${b.volts!.toStringAsFixed(2)} V', kind: RowKind.info),
          ],
          // a supply under ~4.63 V stalls storage and can hang the board
          // (bench 2026-10-13): said where someone looks for power
          if (supplyLow != null)
            SettingRow(
              key: 'supply',
              label: 'Supply',
              value: supplyLow! ? 'Too low: use a 5 V 3 A supply' : 'OK',
              kind: RowKind.info,
            ),
          // what each applet used, and what keeps the device awake
          if (energyAvailable) ...const [
            SettingRow(key: 'battery_use', label: 'Battery use', value: '', kind: RowKind.open),
            SettingRow(key: 'why_awake', label: 'Why it is awake', value: '', kind: RowKind.open),
          ],
          if (canPowerOff) ...const [
            SettingRow(key: 'restart', label: 'Restart', value: '', kind: RowKind.confirm),
            SettingRow(key: 'power_off', label: 'Power off', value: '', kind: RowKind.confirm),
          ],
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
          if (canSetTime) ...const [
            SettingRow(key: 'set_date', label: 'Set the date', value: '', kind: RowKind.open),
            SettingRow(key: 'set_time', label: 'Set the time', value: '', kind: RowKind.open),
          ],
          // the locale's way of writing the time (localed, LC_TIME)
          if (timeLocales.isNotEmpty)
            SettingRow(
              key: 'time_format',
              label: 'Time format',
              value: currentTimeLocale?.example ?? 'System default',
              kind: RowKind.open,
            ),
        ];
      case SettingsCategory.network:
        final n = network;
        final wifi = n?.connected;
        return [
          // each link with its own address: with a cable and Wi-Fi both up
          // there is no single "the address"
          if (n == null || n.wifiPresent)
            SettingRow(
              key: 'wifi',
              label: 'Wi-Fi',
              value: wifi != null ? '${wifi.name} · ${wifi.address}' : (n?.wifiOn == true ? 'Not connected' : 'Off'),
              kind: RowKind.open,
            ),
          SettingRow(
            key: 'ethernet',
            label: 'Wired',
            value: n != null && n.wired ? n.ethernetAddress : 'Not connected',
            kind: RowKind.info,
          ),
        ];
      case SettingsCategory.device:
        // one screen of what the device is: its name (renamed here; the
        // network name follows it, shown only when it differs), the board
        // and its software. A fact the device does not report is left out,
        // never shown as a placeholder.
        final d = device;
        if (d == null) return const [];
        return [
          SettingRow(key: 'name', label: 'Name', value: d.name, kind: RowKind.open),
          if (d.hostname.isNotEmpty && d.hostname != d.name)
            SettingRow(key: 'hostname', label: 'Network name', value: d.hostname, kind: RowKind.info),
          if (d.model.isNotEmpty) SettingRow(key: 'model', label: 'Board', value: d.model, kind: RowKind.info),
          if (d.version.isNotEmpty) SettingRow(key: 'version', label: 'Software version', value: d.version, kind: RowKind.info),
          if (d.memoryMb > 0)
            SettingRow(
              key: 'memory',
              label: 'Memory',
              value: usage.memoryFreeMb > 0
                  ? '${_size(usage.memoryFreeMb)} free of ${_size(d.memoryMb)}'
                  : _size(d.memoryMb),
              kind: RowKind.info,
            ),
          if (usage.dataTotalMb != null)
            SettingRow(
              key: 'storage',
              label: 'Storage',
              value: '${_size(usage.dataFreeMb!)} free of ${_size(usage.dataTotalMb!)}',
              kind: RowKind.info,
            ),
          if (usage.rootFreeMb != null)
            SettingRow(key: 'system_space', label: 'System space', value: '${_size(usage.rootFreeMb!)} free', kind: RowKind.info),
          if (d.serial.isNotEmpty) SettingRow(key: 'serial', label: 'Serial', value: d.serial, kind: RowKind.info),
          if (bluetooth?.present ?? false)
            SettingRow(key: 'devicelink', label: 'Device Link', value: linkValue(bluetooth!), kind: RowKind.open),
          if (usbPresent) const SettingRow(key: 'usbport', label: 'USB', value: '', kind: RowKind.open),
          const SettingRow(key: 'manage', label: 'Manage from a browser', value: '', kind: RowKind.open),
          const SettingRow(key: 'licences', label: 'Licences', value: '', kind: RowKind.open),
          const SettingRow(key: 'setup', label: 'Set up again', value: '', kind: RowKind.open),
        ];
      case SettingsCategory.applets:
        // keys are setting:<applet>:<key>; an enum or bool changes on a
        // tap, a number or text opens the keyboard
        return [
          for (final a in declared)
            for (final decl in a.settings)
              SettingRow(
                key: 'setting:${a.id}:${decl.key}',
                label: '${a.name}: ${decl.label}',
                value: decl.type == 'bool' ? (valueOf(a.id, decl) == 'true' ? 'On' : 'Off') : valueOf(a.id, decl),
                kind: decl.type == 'enum' || decl.type == 'bool' ? RowKind.toggle : RowKind.open,
                on: valueOf(a.id, decl) == 'true',
              ),
        ];
    }
  }

  @override
  SettingsState get snapshot => SettingsState(open: open, pickingZone: pickingZone);
}

/// "388 MB", "1.4 GB".
String _size(int mb) => mb >= 1024 ? '${(mb / 1024).toStringAsFixed(1)} GB' : '$mb MB';

/// What suspension keeps: where the person was.
class SettingsState {
  const SettingsState({required this.open, required this.pickingZone});

  final SettingsCategory? open;
  final bool pickingZone;
}
