import 'dart:math' as math;

import 'package:vrx_kit/vrx_kit.dart';

/// Everything settings reacts to.
/// Everything Settings reacts to (plan 0013 D1: the reducer is the only
/// writer): Back, a screen opened or closed, or the system's facts, as
/// data.
sealed class SettingsAction {
  const SettingsAction();

  static const init = SettingsSignal.init;
  static const back = SettingsSignal.back;
}

enum SettingsSignal implements SettingsAction { init, back }

/// The system's facts (null fields: unchanged; Change for what may become
/// null): the services' states, the declared settings and their values
/// (one applet's file at a time), the look this boot draws, a refusal.
final class SettingsFacts implements SettingsAction {
  const SettingsFacts({
    this.time,
    this.network,
    this.device,
    this.screen,
    this.dimming,
    this.cascade,
    this.canPowerOff,
    this.usbPresent,
    this.bluetooth,
    this.supplyLow,
    this.battery,
    this.usage,
    this.energyAvailable,
    this.energy,
    this.awake,
    this.updatesAvailable,
    this.updateStatus,
    this.updateOffers,
    this.updateInstalling,
    this.updateInstalled,
    this.timeLocales,
    this.timeLocale,
    this.declared,
    this.values,
    this.zones,
    this.runningScheme,
    this.runningDark,
    this.matter,
    this.matterApplets,
    this.matterPayload,
    this.error,
  });

  final TimeState? time;
  final NetworkState? network;
  final DeviceState? device;
  final ScreenState? screen;
  final VrxDimming? dimming;
  final VrxCascade? cascade;
  final bool? canPowerOff;
  final bool? usbPresent;
  final BluetoothState? bluetooth;
  final bool? supplyLow;
  final Change<Battery?>? battery;
  final DeviceUsage? usage;
  final bool? energyAvailable;
  final Change<EnergyReport?>? energy;
  final Change<AwakeReport?>? awake;

  /// Software update (plan 0016 D11): offered where vrxhost answers for
  /// it; the status and offers as read, the version installing (Change:
  /// it ends) and the one installed and waiting for the restart.
  final bool? updatesAvailable;
  final UpdateStatus? updateStatus;
  final List<UpdateOffer>? updateOffers;
  final Change<String?>? updateInstalling;
  final String? updateInstalled;
  final List<TimeLocale>? timeLocales;
  final String? timeLocale;
  final List<AppletSettingsDecl>? declared;

  /// One applet's settings file as read: (its id, its values).
  final (String, Map<String, String>)? values;
  final List<String>? zones;
  final int? runningScheme;
  final bool? runningDark;

  /// vrx-matter's state (plan 0015 D9); never sent where there is none.
  final MatterState? matter;
  final List<MatterApplet>? matterApplets;
  final Change<MatterPayload?>? matterPayload;
  final String? error;
}

/// The person moved: a screen opened or closed (null fields: unchanged).
/// A move clears a shown refusal.
final class SettingsGo implements SettingsAction {
  const SettingsGo({
    this.open,
    this.renaming,
    this.editingSetting,
    this.showingUse,
    this.showingAwake,
    this.showingUpdate,
    this.pickingScheme,
    this.pickingTimeFormat,
    this.settingTime,
    this.pickingZone,
    this.pairing,
  });

  final Change<SettingsCategory?>? open;
  final bool? renaming;
  final Change<(String, String)?>? editingSetting;
  final bool? showingUse;
  final bool? showingAwake;
  final bool? showingUpdate;
  final bool? pickingScheme;
  final bool? pickingTimeFormat;
  final SettingTime? settingTime;
  final bool? pickingZone;

  /// The pairing screen: the QR code and the manual code (plan 0015 D9).
  final bool? pairing;
}

/// Which of the clock's wheels is up (Settings > Time, plan 0011 D14).
enum SettingTime { none, date, time }

/// The settings categories, in the order evrx-rt's Settings lists them.
enum SettingsCategory { display, power, time, network, device, matter, applets }

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
    this.widest,
  });

  final String key;
  final String label;
  final String value;
  final RowKind kind;

  /// A toggle's widest value among its choices: the row lays itself out
  /// for it, so stepping a choice never makes it jump (plan 0013 D12).
  final String? widest;

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

/// How the on-screen keyboard's mode reads (plan 0013 D6).
String keyboardModeLabel(VrxKeyboardMode mode) => switch (mode) {
      VrxKeyboardMode.auto => 'Only without a keyboard',
      VrxKeyboardMode.show => 'Show',
    };

/// What a tap on "On-screen keyboard" sets.
VrxKeyboardMode nextKeyboardMode(VrxKeyboardMode mode) =>
    mode == VrxKeyboardMode.auto ? VrxKeyboardMode.show : VrxKeyboardMode.auto;

/// The screen-off choices, in seconds (0 = never), and how each reads.
/// The compositor reads `light_off` from the screen's settings file
/// (/etc/vrx/display/screen.conf, plan 0010 D7); vrx-policy seeds it.
const lightOffChoices = [0, 30, 60, 120, 300, 600];

/// The longest of a toggle's choices, by characters (the row measures it
/// in its own type).
String? _widest(Iterable<String> choices) =>
    choices.fold<String?>(null, (w, c) => w == null || c.length > w.length ? c : w);

String lightOffLabel(int seconds) => switch (seconds) {
      0 => 'Never',
      < 60 => '$seconds s',
      < 3600 => '${seconds ~/ 60} min',
      _ => '${seconds ~/ 3600} h',
    };

/// The cascade's later steps (plan 0012 D13), in seconds from the last
/// input (0 = never): sleep and deep sleep come after the screen goes off.
const cascadeChoices = [0, 300, 600, 1800, 3600, 7200];

/// The next of [cascadeChoices] after [now] that comes later than
/// [after] (0 = never is always a choice).
int nextCascade(int now, int after) {
  final allowed = [for (final c in cascadeChoices) if (c == 0 || c > after) c];
  final i = allowed.indexOf(now);
  return allowed[(i + 1) % allowed.length];
}

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
  ScreenState display = const ScreenState();
  VrxDimming dimming = VrxDimming.none;

  /// The cascade's steps the board offers after the screen (plan 0012
  /// D13, D14): no "Sleep after" where sleep is not worth it or nothing
  /// can wake the board, no "Power off when idle" without a timed wake.
  VrxCascade cascade = const VrxCascade();
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

  /// Software update (plan 0016 D11): the screen open, what vrxhost said
  /// (offers null while they load), the install under way and done.
  bool updatesAvailable = false;
  bool showingUpdate = false;
  UpdateStatus? updateStatus;
  List<UpdateOffer>? updateOffers;
  String? updateInstalling;
  String? updateInstalled;

  /// Device's Software update row value.
  String get updateSummary => updateInstalled != null
      ? 'Restart to finish'
      : switch (updateStatus?.last) {
          UpdateOutcome.fellBack => 'Went back',
          UpdateOutcome.trial => 'On trial',
          _ => updateStatus?.running ?? '',
        };

  /// The installed locales and the one LC_TIME is now (plan 0011 D7).
  List<TimeLocale> timeLocales = const [];
  String timeLocale = '';
  bool pickingTimeFormat = false;
  SettingTime settingTime = SettingTime.none;
  /// Applets' declared settings (vrxhost) and their values (the files).
  List<AppletSettingsDecl> declared = const [];
  final values = <String, Map<String, String>>{};

  /// Matter (plan 0015 D8, D9): null where the image has no vrx-matter.
  MatterState? matter;
  List<MatterApplet> matterApplets = const [];
  MatterPayload? matterPayload;
  bool pairing = false;

  /// What a home app may see: the system settings file's (D8).
  MatterExposure get exposure => MatterExposure.of(values['vrx'] ?? const {});

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
    switch (action) {
      case SettingsFacts f:
        time = f.time ?? time;
        network = f.network ?? network;
        device = f.device ?? device;
        display = f.screen ?? display;
        dimming = f.dimming ?? dimming;
        cascade = f.cascade ?? cascade;
        canPowerOff = f.canPowerOff ?? canPowerOff;
        usbPresent = f.usbPresent ?? usbPresent;
        bluetooth = f.bluetooth ?? bluetooth;
        supplyLow = f.supplyLow ?? supplyLow;
        if (f.battery != null) battery = f.battery!.value;
        usage = f.usage ?? usage;
        energyAvailable = f.energyAvailable ?? energyAvailable;
        if (f.energy != null) energy = f.energy!.value;
        if (f.awake != null) awake = f.awake!.value;
        updatesAvailable = f.updatesAvailable ?? updatesAvailable;
        updateStatus = f.updateStatus ?? updateStatus;
        updateOffers = f.updateOffers ?? updateOffers;
        if (f.updateInstalling != null) updateInstalling = f.updateInstalling!.value;
        updateInstalled = f.updateInstalled ?? updateInstalled;
        timeLocales = f.timeLocales ?? timeLocales;
        timeLocale = f.timeLocale ?? timeLocale;
        declared = f.declared ?? declared;
        if (f.values case (final id, final v)?) values[id] = v;
        zones = f.zones ?? zones;
        runningScheme = f.runningScheme ?? runningScheme;
        runningDark = f.runningDark ?? runningDark;
        matter = f.matter ?? matter;
        matterApplets = f.matterApplets ?? matterApplets;
        if (f.matterPayload != null) matterPayload = f.matterPayload!.value;
        // the window closed (timed out, or a home app paired): the codes go
        if (matter?.window == false) matterPayload = null;
        if (f.error != null) error = f.error;
      case SettingsGo g:
        error = null;
        if (g.open != null) open = g.open!.value;
        renaming = g.renaming ?? renaming;
        if (g.editingSetting != null) editingSetting = g.editingSetting!.value;
        showingUse = g.showingUse ?? showingUse;
        showingAwake = g.showingAwake ?? showingAwake;
        showingUpdate = g.showingUpdate ?? showingUpdate;
        pickingScheme = g.pickingScheme ?? pickingScheme;
        pickingTimeFormat = g.pickingTimeFormat ?? pickingTimeFormat;
        settingTime = g.settingTime ?? settingTime;
        pickingZone = g.pickingZone ?? pickingZone;
        pairing = g.pairing ?? pairing;
        // a report screen opens empty and fills when the estimate arrives
        if (g.showingUse == true) energy = null;
        if (g.showingAwake == true) awake = null;
        if (g.showingUpdate == true) updateOffers = null;
      case SettingsSignal.back:
        error = null;
        _back();
      case SettingsSignal.init:
        break;
    }
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
        // pairing with a home app (plan 0015), where the image has Matter
        if (matter != null)
          CategoryRow(SettingsCategory.matter, 'Matter', 'smartphone', matter!.commissioned ? 'Paired' : ''),
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
  int get lightOff => display.lightOff;

  String get _screenOffText => lightOff == 0 ? 'Stays on' : 'Off after ${lightOffLabel(lightOff)}';

  /// What a tap on "Sleep after" sets: a step later than the screen's.
  int get nextSleepAfter => nextCascade(display.sleepAfter, lightOff);

  /// What a tap on "Power off when idle" sets: later than sleep's too.
  int get nextDeepAfter => nextCascade(display.deepAfter, math.max(lightOff, cascade.sleep ? display.sleepAfter : 0));

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
              value: '${display.brightness}',
              kind: RowKind.slider,
              level: display.brightness,
            ),
          // a tap steps through the choices; the compositor watches the file
          SettingRow(
            key: 'light_off',
            label: 'Screen off after',
            value: lightOffLabel(lightOff),
            kind: RowKind.toggle,
            widest: _widest(lightOffChoices.map(lightOffLabel)),
          ),
          // the cascade's later steps, where the board offers them
          if (cascade.sleep)
            SettingRow(
              key: 'sleep_after',
              label: 'Sleep after',
              value: lightOffLabel(display.sleepAfter),
              kind: RowKind.toggle,
              widest: _widest(lightOffChoices.map(lightOffLabel)),
            ),
          if (cascade.deep)
            SettingRow(
              key: 'deep_after',
              label: 'Power off when idle',
              value: display.deepAfter == 0 ? 'Never' : 'After ${lightOffLabel(display.deepAfter)}',
              kind: RowKind.toggle,
              widest: _widest(['Never', for (final c in lightOffChoices) 'After ${lightOffLabel(c)}']),
            ),
          // Reduce motion (plan 0017 D5): travel lands at once; it only ever
          // takes motion away, and an e-paper build stays still whatever it says
          SettingRow(
            key: 'reduce_motion',
            label: 'Reduce motion',
            value: display.reduceMotion ? 'On' : 'Off',
            kind: RowKind.toggle,
            on: display.reduceMotion,
            widest: 'Off',
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
              widest: 'Off',
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
            widest: 'Off',
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
          // installing a signed update (plan 0016 D11), where the image can
          if (updatesAvailable) SettingRow(key: 'software_update', label: 'Software update', value: updateSummary, kind: RowKind.open),
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
          // when the on-screen keyboard comes up for a text field (plan
          // 0013 D6): only without a physical keyboard, or always
          SettingRow(
            key: 'on_screen_keyboard',
            label: 'On-screen keyboard',
            value: keyboardModeLabel(display.keyboard),
            kind: RowKind.toggle,
            widest: _widest(VrxKeyboardMode.values.map(keyboardModeLabel)),
          ),
          const SettingRow(key: 'manage', label: 'Manage from a browser', value: '', kind: RowKind.open),
          const SettingRow(key: 'licences', label: 'Licences', value: '', kind: RowKind.open),
          const SettingRow(key: 'setup', label: 'Set up again', value: '', kind: RowKind.open),
        ];
      case SettingsCategory.matter:
        final m = matter;
        if (m == null) return const [];
        final shown = exposure;
        return [
          SettingRow(
            key: 'matter_pair',
            label: 'Pair with a home app',
            value: m.window && m.windowUntil != null ? 'Open until ${_hm(m.windowUntil!)}' : '',
            kind: RowKind.open,
          ),
          SettingRow(
            key: 'matter_fabrics',
            label: 'Home apps',
            value: m.fabrics == 0 ? 'None' : '${m.fabrics}',
            kind: RowKind.info,
          ),
          // what a home app may see (D8): the screen on by default, an
          // applet once switched on here
          SettingRow(
            key: 'matter_screen',
            label: 'Show the screen',
            value: shown.screen ? 'On' : 'Off',
            kind: RowKind.toggle,
            on: shown.screen,
            widest: 'Off',
          ),
          for (final a in matterApplets)
            SettingRow(
              key: 'matter_expose:${a.id}',
              label: 'Show ${a.name}',
              value: shown.applets.contains(a.id) ? 'On' : 'Off',
              kind: RowKind.toggle,
              on: shown.applets.contains(a.id),
              widest: 'Off',
            ),
          // a debug image's test attestation: home apps warn about it
          if (m.attestation == 'test')
            const SettingRow(key: 'matter_attestation', label: 'Certification', value: 'Test device', kind: RowKind.info),
          if (m.commissioned)
            const SettingRow(key: 'matter_forget', label: 'Remove from every home app', value: '', kind: RowKind.confirm),
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
                widest: switch (decl.type) {
                  'bool' => 'Off',
                  'enum' => _widest(decl.options),
                  _ => null,
                },
              ),
        ];
    }
  }

  @override
  SettingsState get snapshot => SettingsState(open: open, pickingZone: pickingZone);

  /// Back, one screen, in the order the screens stack over a category.
  void _back() {
    if (renaming) {
      renaming = false;
    } else if (pairing) {
      pairing = false;
    } else if (editingSetting != null) {
      editingSetting = null;
    } else if (showingUpdate) {
      showingUpdate = false;
    } else if (showingUse) {
      showingUse = false;
    } else if (showingAwake) {
      showingAwake = false;
    } else if (pickingScheme) {
      pickingScheme = false;
    } else if (pickingTimeFormat) {
      pickingTimeFormat = false;
    } else if (settingTime != SettingTime.none) {
      settingTime = SettingTime.none;
    } else if (pickingZone) {
      pickingZone = false;
    } else {
      open = null;
    }
  }

  @override
  void restore(SettingsState snapshot) {
    open = snapshot.open;
    pickingZone = snapshot.pickingZone;
  }

  @override
  SettingsAction get backAction => SettingsAction.back;

  /// The categories are the root: whatever was open over them, Back from
  /// the list leaves.
  @override
  bool get atRoot => open == null;

  // the screens over the categories (plan 0017 D6): the category, then
  // whatever is open over it; each is a screen, so a change slides
  @override
  Object get screen => [
        open,
        renaming,
        editingSetting,
        pairing,
        showingUpdate,
        showingUse,
        showingAwake,
        pickingScheme,
        pickingTimeFormat,
        settingTime,
        pickingZone,
      ];

  @override
  int get depth {
    if (open == null) return 0;
    final over = renaming ||
        editingSetting != null ||
        pairing ||
        showingUpdate ||
        showingUse ||
        showingAwake ||
        pickingScheme ||
        pickingTimeFormat ||
        settingTime != SettingTime.none ||
        pickingZone;
    return over ? 2 : 1;
  }

  @override
  Object? get fingerprint => [
        time?.zone, time?.automatic, time?.synced, network?.ethernetAddress, device?.name, display.lightOff,
        display.brightness, display.sleepAfter, display.deepAfter, dimming, cascade.sleep, cascade.deep, canPowerOff,
        usbPresent, bluetooth?.on, supplyLow, battery?.percent, energyAvailable, energy == null, awake == null,
        updatesAvailable, updateStatus?.running, updateStatus?.last, updateStatus?.trial,
        [for (final o in updateOffers ?? const <UpdateOffer>[]) o.file], updateOffers == null, updateInstalling,
        updateInstalled, showingUpdate,
        [for (final l in timeLocales) l.name], timeLocale, [for (final d in declared) d.id], values, zones,
        runningScheme, runningDark, matter, [for (final a in matterApplets) a.id], matterPayload?.manual, pairing,
        error, open, renaming, editingSetting?.$1, editingSetting?.$2, showingUse,
        showingAwake, pickingScheme, pickingTimeFormat, settingTime, pickingZone,
      ];
}

/// "14:05": when the pairing window closes.
String _hm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// "388 MB", "1.4 GB".
String _size(int mb) => mb >= 1024 ? '${(mb / 1024).toStringAsFixed(1)} GB' : '$mb MB';

/// What suspension keeps: where the person was.
class SettingsState {
  const SettingsState({required this.open, required this.pickingZone});

  final SettingsCategory? open;
  final bool pickingZone;

  @override
  bool operator ==(Object other) => other is SettingsState && other.open == open && other.pickingZone == pickingZone;

  @override
  int get hashCode => Object.hash(open, pickingZone);

  @override
  String toString() => 'SettingsState($open, $pickingZone)';
}
