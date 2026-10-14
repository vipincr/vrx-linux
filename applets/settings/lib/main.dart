import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' hide Intent; // vrx's Intent
import 'package:vrx_kit/vrx_kit.dart';

import 'energy.dart';
import 'state.dart';

/// Facts from the system services, for the applet's whole life.
final _facts = StreamController<SettingsAction>();

/// The settings files (plan 0008 D5): this applet holds the settings grant.
final _settings = AppletSettings();

/// The screen's settings (plan 0010 D7): the display grant.
final _screen = ScreenSettings();

/// The settings applet: the system's own settings, each row bound to the
/// Linux service that owns it (plan 0008 Part D): time and zone through
/// timedated, the device name through hostnamed, power through logind,
/// the screen through ScreenSettings (the backlight's own attribute, or
/// the compositor's file where there is none to dim).
/// A tap asks the service; the row
/// changes when the service says it changed, so what is shown is what
/// is true. A refusal (no grant) is shown as the service phrased it.
class SettingsApplet extends Applet<SettingsState, SettingsAction, SettingsView> {
  SettingsApplet(this.model);

  final SettingsModel model;

  @override
  SettingsState get initial => model.initial;

  @override
  SettingsAction get bootAction => model.bootAction;

  @override
  SettingsView reduce(SettingsState state, SettingsAction action) =>
      model.reduce(state, action);

  @override
  SettingsState get snapshot => model.snapshot;

  @override
  bool get followsRoutes => true;

  // opened at a category (plan 0011 D5): `time` from Clock; anything else
  // keeps where the person was
  @override
  SettingsAction? onRoute(String route, Object? payload) {
    if (route != 'time') return null;
    model
      ..open = SettingsCategory.time
      ..pickingZone = false
      ..settingTime = SettingTime.none;
    return SettingsAction.navigated;
  }

  void _go(BuildContext context, void Function() change) {
    change();
    AppletScope.dispatch(context, SettingsAction.navigated);
  }

  Future<void> _ask(BuildContext context, Future<void> Function() call) async {
    try {
      await call();
    } on Object catch (err) {
      model.error = VrxWords.of(err, context: 'settings');
      _facts.add(SettingsAction.failed);
    }
  }

  @override
  Widget build(BuildContext context, SettingsView view) {
    final open = view.open;
    final Widget body;
    if (open == null) {
      body = _Categories(view: view, onOpen: (c) => _go(context, () => model.open = c));
    } else if (view.renaming) {
      body = VrxTextEntry(
        title: 'Name',
        initial: model.device?.name ?? '',
        helper: (text) => 'Network name: ${hostnameFor(text)}',
        onBack: () => _go(context, () => model.renaming = false),
        onDone: (name) {
          _go(context, () => model.renaming = false);
          if (name.trim().isNotEmpty) unawaited(_ask(context, () => VrxSystem.device.setName(name.trim())));
        },
      );
    } else if (model.editingSetting != null) {
      final (applet, key) = model.editingSetting!;
      final decl = model.declOf(applet, key);
      body = VrxTextEntry(
        title: decl?.label ?? key,
        initial: decl == null ? '' : model.valueOf(applet, decl),
        onBack: () => _go(context, () => model.editingSetting = null),
        onDone: (text) {
          _go(context, () => model.editingSetting = null);
          unawaited(_setSetting(applet, key, text.trim()));
        },
      );
    } else if (model.showingUse) {
      body = BatteryUseScreen(report: model.energy, onBack: () => _go(context, () => model.showingUse = false));
    } else if (model.showingAwake) {
      body = WhyAwakeScreen(
        awake: model.awake,
        names: {for (final r in model.energy?.rows ?? const <EnergyRow>[]) r.key: r.name},
        onBack: () => _go(context, () => model.showingAwake = false),
      );
    } else if (model.pickingScheme) {
      body = VrxSchemePicker(
        current: model.runningScheme,
        chosen: model.chosenScheme,
        dark: model.chosenDark,
        onBack: () => _go(context, () => model.pickingScheme = false),
        onPick: (id) {
          _go(context, () => model.pickingScheme = false);
          unawaited(_setSetting('vrx', 'scheme', '$id'));
        },
      );
    } else if (view.pickingTimeFormat) {
      body = VrxList(children: [
        VrxHeader(title: 'Time format', onBack: () => _go(context, () => model.pickingTimeFormat = false)),
        for (final l in view.timeLocales)
          VrxRow(
            label: l.timeExample,
            detail: '${l.dateExample} · ${l.name}',
            valueGlyph: l.name == model.timeLocale ? VrxSymbols.check : null,
            onTap: () {
              _go(context, () => model.pickingTimeFormat = false);
              unawaited(_ask(context, () async {
                await VrxSystem.locale.setTimeLocale(l.name);
                model.timeLocale = await VrxSystem.locale.timeLocale();
                _facts.add(SettingsAction.factsChanged);
              }));
            },
          ),
      ]);
    } else if (view.settingTime == SettingTime.date) {
      body = VrxDatePicker(
        title: 'Set the date',
        date: DateTime.now(),
        onBack: () => _go(context, () => model.settingTime = SettingTime.none),
        onSet: (d) {
          _go(context, () => model.settingTime = SettingTime.none);
          final now = DateTime.now();
          unawaited(_ask(context, () => VrxSystem.time.setTime(DateTime(d.year, d.month, d.day, now.hour, now.minute, now.second))));
        },
      );
    } else if (view.settingTime == SettingTime.time) {
      final now = DateTime.now();
      body = VrxTimePicker(
        title: 'Set the time',
        minutes: now.hour * 60 + now.minute,
        onBack: () => _go(context, () => model.settingTime = SettingTime.none),
        onSet: (m) {
          _go(context, () => model.settingTime = SettingTime.none);
          final t = DateTime.now();
          unawaited(_ask(context, () => VrxSystem.time.setTime(DateTime(t.year, t.month, t.day, m ~/ 60, m % 60))));
        },
      );
    } else if (view.pickingZone) {
      body = VrxZonePicker(
        title: 'Time zone',
        zones: view.zones,
        current: model.time?.zone ?? '',
        onBack: () => _go(context, () => model.pickingZone = false),
        onPick: (zone) {
          _go(context, () => model.pickingZone = false);
          unawaited(_ask(context, () => VrxSystem.time.setZone(zone)));
        },
      );
    } else {
      body = _Category(
        view: view,
        category: open,
        onBack: () => _go(context, () => model.open = null),
        onRow: (row) => _onRow(context, row),
        onLevel: (row, v, settled) => _brightness(context, v, settled: settled),
      );
    }
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          Expanded(child: body),
          if (view.error != null) VrxBanner(text: view.error),
        ]),
      ),
    );
  }

  Future<void> _setSetting(String applet, String key, String value) async {
    final decl = model.declOf(applet, key);
    if (decl != null && (decl.type == 'int' || decl.type == 'float') && num.tryParse(value) == null) {
      model.error = '${decl.label} takes a number';
      _facts.add(SettingsAction.failed);
      return;
    }
    try {
      await _settings.set(applet, key, value);
    } on FileSystemException catch (err) {
      model.error = VrxWords.of(err, context: 'settings: save');
      _facts.add(SettingsAction.failed);
    }
  }

  void _brightness(BuildContext context, int value, {required bool settled}) =>
      unawaited(_ask(context, () => _screen.setBrightness(value, settled: settled)));

  void _onRow(BuildContext context, SettingRow row) {
    if (row.key.startsWith('setting:')) {
      final parts = row.key.split(':');
      final applet = parts[1], key = parts.sublist(2).join(':');
      final decl = model.declOf(applet, key);
      if (decl == null) return;
      if (row.kind == RowKind.toggle) {
        unawaited(_setSetting(applet, key, model.nextValue(applet, decl)));
      } else {
        _go(context, () => model.editingSetting = (applet, key));
      }
      return;
    }
    switch (row.key) {
      case 'wifi':
      case 'devicelink':
      case 'usbport':
      case 'manage':
        // their own applets (no tile): a trail push, vrxhost starts them
        unawaited(Nav.push(row.key));
      // at the route that says why it was opened (plan 0011 D5)
      case 'setup':
        unawaited(Nav.push('setup', route: 'again'));
      case 'licences':
        unawaited(Nav.push('docs', route: 'licences'));
      case 'name':
        _go(context, () => model.renaming = true);
      case 'battery_use':
        _go(context, () => model
          ..showingUse = true
          ..energy = null);
        unawaited(_ask(context, () async {
          model.energy = await VrxEnergy.service.energy();
          _facts.add(SettingsAction.factsChanged);
        }));
      case 'why_awake':
        _go(context, () => model
          ..showingAwake = true
          ..awake = null);
        unawaited(_ask(context, () async {
          model
            ..awake = await VrxEnergy.service.awake()
            ..energy ??= await VrxEnergy.service.energy(hours: 1);
          _facts.add(SettingsAction.factsChanged);
        }));
      case 'light_off':
        unawaited(_ask(context, () => _screen.setLightOff(model.nextLightOff)));
      case 'scheme':
        _go(context, () => model.pickingScheme = true);
      case 'polarity':
        unawaited(_setSetting('vrx', 'polarity', row.on ? 'light' : 'dark'));
      case 'time_format':
        _go(context, () => model.pickingTimeFormat = true);
      case 'set_date':
        _go(context, () => model.settingTime = SettingTime.date);
      case 'set_time':
        _go(context, () => model.settingTime = SettingTime.time);
      case 'automatic':
        unawaited(_ask(context, () => VrxSystem.time.setAutomatic(!row.on)));
      case 'zone':
        _go(context, () => model.pickingZone = true);
        if (model.zones.isEmpty) {
          unawaited(_ask(context, () async {
            model.zones = await VrxSystem.time.zones();
            _facts.add(SettingsAction.zonesLoaded);
          }));
        }
      case 'restart':
      case 'power_off':
        final off = row.key == 'power_off';
        unawaited(() async {
          final yes = await vrxConfirm(
            context,
            title: off ? 'Power off?' : 'Restart?',
            message: off
                ? 'The device turns off. It starts again when its power button or supply says so.'
                : 'Every applet closes and the device starts again.',
            act: off ? 'Power off' : 'Restart',
          );
          if (yes && context.mounted) unawaited(_ask(context, off ? VrxSystem.power.powerOff : VrxSystem.power.reboot));
        }());
    }
  }
}

class _Categories extends StatelessWidget {
  const _Categories({required this.view, required this.onOpen});

  final SettingsView view;
  final void Function(SettingsCategory) onOpen;

  @override
  Widget build(BuildContext context) {
    return VrxList(children: [
      // Back leaves the applet: a trail pop, vrxhost's decision
      const VrxHeader(title: 'Settings', onBack: Nav.pop),
      for (final c in view.categories)
        VrxRow(
          glyph: VrxSymbols.named(c.glyph),
          label: c.label,
          value: c.summary.isEmpty ? '›' : '${c.summary}  ›',
          onTap: () => onOpen(c.category),
        ),
    ]);
  }
}

class _Category extends StatelessWidget {
  const _Category({
    required this.view,
    required this.category,
    required this.onBack,
    required this.onRow,
    required this.onLevel,
  });

  final SettingsView view;
  final SettingsCategory category;
  final VoidCallback onBack;
  final void Function(SettingRow) onRow;

  /// A slider moved (settled: it came to rest).
  final void Function(SettingRow row, int value, bool settled) onLevel;

  static const _titles = {
    SettingsCategory.display: 'Display',
    SettingsCategory.power: 'Power',
    SettingsCategory.time: 'Time',
    SettingsCategory.network: 'Network',
    SettingsCategory.device: 'Device',
    SettingsCategory.applets: 'Applets',
  };

  @override
  Widget build(BuildContext context) {
    return VrxList(children: [
      // back within the applet: the category list
      VrxHeader(title: _titles[category] ?? '', onBack: onBack),
      for (final row in view.rows)
        switch (row.kind) {
          // a switch reads On or Off, an applet's enum its value: the
          // model has already put the words in row.value
          RowKind.toggle => VrxRow(label: row.label, value: row.value, onTap: () => onRow(row)),
          RowKind.open => VrxRow(label: row.label, value: '${row.value}  ›', onTap: () => onRow(row)),
          RowKind.confirm => VrxRow(label: row.label, value: '', onTap: () => onRow(row)),
          RowKind.info => VrxRow(label: row.label, value: row.value),
          // the label as a status line, the slider under it at the inset
          RowKind.slider => Column(mainAxisSize: MainAxisSize.min, children: [
              VrxRow(label: row.label, value: row.value),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: ScaledSpacing.of(context).inset),
                child: VrxSlider(
                  label: row.label,
                  value: row.level,
                  onChanged: (v) => onLevel(row, v, false),
                  onChangeEnd: (v) => onLevel(row, v, true),
                ),
              ),
            ]),
        },
    ]);
  }
}

Future<void> main() async {
  final model = SettingsModel();
  runApplet(SettingsApplet(model), actions: _facts.stream);
  void fact(void Function() change) {
    change();
    _facts.add(SettingsAction.factsChanged);
  }

  void failed(Object err) {
    model.error = VrxWords.of(err, context: 'settings');
    _facts.add(SettingsAction.failed);
  }

  // each service on its own: one that is absent (a desktop run) leaves
  // the others working
  VrxSystem.time.watch().listen((t) => fact(() => model.time = t), onError: failed);
  VrxSystem.network.watch().listen((n) => fact(() => model.network = n), onError: failed);
  VrxSystem.device.watch().listen((d) => fact(() => model.device = d), onError: failed);
  _screen.watch().listen((s) => fact(() => model.screen = s), onError: failed);
  unawaited(_screen.dimming().then((d) => fact(() => model.dimming = d)));
  VrxSystem.power.watchSupplyLow().listen((low) => fact(() => model.supplyLow = low), onError: failed);
  VrxSystem.usb.watch().listen((u) => fact(() => model.usbPresent = u.present), onError: failed);
  VrxSystem.bluetooth.watch().listen((b) => fact(() => model.bluetooth = b), onError: failed);
  VrxSystem.powerSupply.watch().listen((b) => fact(() => model.battery = b), onError: failed);
  unawaited(deviceUsage().then((u) => fact(() => model.usage = u)));
  // vrxhost's energy estimate (plan 0012 D12): on a device with vrxhost
  if (AppletsService.installed != null) fact(() => model.energyAvailable = true);
  // the locales a time format can come from, and LC_TIME now (localed)
  unawaited(() async {
    try {
      final locales = await VrxSystem.locale.timeLocales();
      final now = await VrxSystem.locale.timeLocale();
      fact(() => model
        ..timeLocales = locales
        ..timeLocale = now);
    } on Object catch (err) {
      debugPrint('settings: no locales: $err');
    }
  }());
  // the look this boot draws, from the same snapshot every applet reads
  final boot = bootColors();
  model
    ..runningScheme = boot.scheme
    ..runningDark = boot.dark;
  // the system's own settings (the chosen look)
  _settings.watch('vrx').listen((v) => fact(() => model.values['vrx'] = v), onError: failed);
  // applets' declared settings, each file watched so a change shows
  unawaited(() async {
    final service = AppletsService.installed;
    if (service == null) return;
    try {
      final declared = await service.settings();
      fact(() => model.declared = declared);
      for (final a in declared) {
        _settings.watch(a.id).listen((v) => fact(() => model.values[a.id] = v), onError: failed);
      }
    } on Object catch (err) {
      failed(err);
    }
  }());
  try {
    final canOff = await VrxSystem.power.canPowerOff();
    fact(() => model.canPowerOff = canOff);
  } on Object catch (err) {
    failed(err);
  }
}
