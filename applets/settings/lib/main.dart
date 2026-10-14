import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' hide Intent; // vrx's Intent
import 'package:vrx_kit/vrx_kit.dart';

import 'energy.dart';
import 'state.dart';
import 'update.dart';

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
  SettingsAction? onRoute(String route, Object? payload) => route == 'time'
      ? const SettingsGo(open: Change(SettingsCategory.time), pickingZone: false, settingTime: SettingTime.none)
      : null;

  void _go(BuildContext context, SettingsGo move) => AppletScope.dispatch(context, move);

  Future<void> _ask(BuildContext context, Future<void> Function() call) async {
    try {
      await call();
    } on Object catch (err) {
      _facts.add(SettingsFacts(error: VrxWords.of(err, context: 'settings')));
    }
  }

  @override
  Widget build(BuildContext context, SettingsView view) {
    final open = view.open;
    final Widget body;
    if (open == null) {
      body = _Categories(view: view, onOpen: (c) => _go(context, SettingsGo(open: Change(c))));
    } else if (view.renaming) {
      body = VrxTextEntry(
        title: 'Name',
        initial: model.device?.name ?? '',
        helper: (text) => 'Network name: ${hostnameFor(text)}',
        onBack: () => _go(context, const SettingsGo(renaming: false)),
        onDone: (name) {
          _go(context, const SettingsGo(renaming: false));
          if (name.trim().isNotEmpty) unawaited(_ask(context, () => VrxSystem.device.setName(name.trim())));
        },
      );
    } else if (model.editingSetting != null) {
      final (applet, key) = model.editingSetting!;
      final decl = model.declOf(applet, key);
      body = VrxTextEntry(
        title: decl?.label ?? key,
        initial: decl == null ? '' : model.valueOf(applet, decl),
        onBack: () => _go(context, const SettingsGo(editingSetting: Change(null))),
        onDone: (text) {
          _go(context, const SettingsGo(editingSetting: Change(null)));
          unawaited(_setSetting(applet, key, text.trim()));
        },
      );
    } else if (model.pairing) {
      body = MatterPairing(
        state: model.matter,
        payload: model.matterPayload,
        onBack: () => _go(context, const SettingsGo(pairing: false)),
        onClose: () {
          _go(context, const SettingsGo(pairing: false));
          unawaited(_ask(context, () async => VrxMatter.service?.closeWindow()));
        },
      );
    } else if (model.showingUpdate) {
      body = SoftwareUpdateScreen(
        status: model.updateStatus,
        offers: model.updateOffers,
        installing: model.updateInstalling,
        installed: model.updateInstalled,
        onInstall: (offer) => unawaited(installUpdate(offer, _facts.add)),
        onRestart: () => unawaited(
            restartIntoUpdate(context, model.updateInstalled ?? '', model.updateStatus?.running ?? '', _facts.add)),
        onBack: () => _go(context, const SettingsGo(showingUpdate: false)),
      );
    } else if (model.showingUse) {
      body = BatteryUseScreen(report: model.energy, onBack: () => _go(context, const SettingsGo(showingUse: false)));
    } else if (model.showingAwake) {
      body = WhyAwakeScreen(
        awake: model.awake,
        names: {for (final r in model.energy?.rows ?? const <EnergyRow>[]) r.key: r.name},
        onBack: () => _go(context, const SettingsGo(showingAwake: false)),
      );
    } else if (model.pickingScheme) {
      body = VrxSchemePicker(
        current: model.runningScheme,
        chosen: model.chosenScheme,
        dark: model.chosenDark,
        onBack: () => _go(context, const SettingsGo(pickingScheme: false)),
        onPick: (id) {
          _go(context, const SettingsGo(pickingScheme: false));
          unawaited(_setSetting('vrx', 'scheme', '$id'));
        },
      );
    } else if (view.pickingTimeFormat) {
      body = VrxList(children: [
        VrxHeader(title: 'Time format', onBack: () => _go(context, const SettingsGo(pickingTimeFormat: false))),
        for (final l in view.timeLocales)
          VrxRow(
            label: l.timeExample,
            detail: '${l.dateExample} · ${l.name}',
            valueGlyph: l.name == model.timeLocale ? VrxSymbols.check : null,
            onTap: () {
              _go(context, const SettingsGo(pickingTimeFormat: false));
              unawaited(_ask(context, () async {
                await VrxSystem.locale.setTimeLocale(l.name);
                _facts.add(SettingsFacts(timeLocale: await VrxSystem.locale.timeLocale()));
              }));
            },
          ),
      ]);
    } else if (view.settingTime == SettingTime.date) {
      body = VrxDatePicker(
        title: 'Set the date',
        date: DateTime.now(),
        onBack: () => _go(context, const SettingsGo(settingTime: SettingTime.none)),
        onSet: (d) {
          _go(context, const SettingsGo(settingTime: SettingTime.none));
          final now = DateTime.now();
          unawaited(_ask(context, () => VrxSystem.time.setTime(DateTime(d.year, d.month, d.day, now.hour, now.minute, now.second))));
        },
      );
    } else if (view.settingTime == SettingTime.time) {
      final now = DateTime.now();
      body = VrxTimePicker(
        title: 'Set the time',
        minutes: now.hour * 60 + now.minute,
        onBack: () => _go(context, const SettingsGo(settingTime: SettingTime.none)),
        onSet: (m) {
          _go(context, const SettingsGo(settingTime: SettingTime.none));
          final t = DateTime.now();
          unawaited(_ask(context, () => VrxSystem.time.setTime(DateTime(t.year, t.month, t.day, m ~/ 60, m % 60))));
        },
      );
    } else if (view.pickingZone) {
      body = VrxZonePicker(
        title: 'Time zone',
        zones: view.zones,
        current: model.time?.zone ?? '',
        onBack: () => _go(context, const SettingsGo(pickingZone: false)),
        onPick: (zone) {
          _go(context, const SettingsGo(pickingZone: false));
          unawaited(_ask(context, () => VrxSystem.time.setZone(zone)));
        },
      );
    } else {
      body = _Category(
        view: view,
        category: open,
        onBack: () => _go(context, const SettingsGo(open: Change(null))),
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
      _facts.add(SettingsFacts(error: '${decl.label} takes a number'));
      return;
    }
    try {
      await _settings.set(applet, key, value);
    } on FileSystemException catch (err) {
      _facts.add(SettingsFacts(error: VrxWords.of(err, context: 'settings: save')));
    }
  }

  void _brightness(BuildContext context, int value, {required bool settled}) =>
      unawaited(_ask(context, () => _screen.setBrightness(value, settled: settled)));

  void _onRow(BuildContext context, SettingRow row) {
    if (row.key.startsWith('matter_expose:')) {
      final id = row.key.substring('matter_expose:'.length);
      unawaited(_setSetting('vrx', 'matter_expose', model.exposure.exposing(id, on: !row.on)));
      return;
    }
    if (row.key.startsWith('setting:')) {
      final parts = row.key.split(':');
      final applet = parts[1], key = parts.sublist(2).join(':');
      final decl = model.declOf(applet, key);
      if (decl == null) return;
      if (row.kind == RowKind.toggle) {
        unawaited(_setSetting(applet, key, model.nextValue(applet, decl)));
      } else {
        _go(context, SettingsGo(editingSetting: Change((applet, key))));
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
        _go(context, const SettingsGo(renaming: true));
      case 'matter_pair':
        // the window opens and the codes show; a home app has 15 minutes
        _go(context, const SettingsGo(pairing: true));
        unawaited(_ask(context, () async {
          final matter = VrxMatter.service;
          if (matter == null) return;
          if (model.matter?.window != true) await matter.openWindow();
          _facts.add(SettingsFacts(matterPayload: Change(await matter.payload())));
        }));
      case 'matter_screen':
        unawaited(_setSetting('vrx', 'matter_screen', row.on ? 'false' : 'true'));
      case 'matter_forget':
        unawaited(() async {
          final yes = await vrxConfirm(
            context,
            title: 'Remove from every home app?',
            message: 'Each home app loses this device and its controls. It can be paired again.',
            act: 'Remove',
          );
          if (yes && context.mounted) unawaited(_ask(context, () async => VrxMatter.service?.forget()));
        }());
      case 'software_update':
        _go(context, const SettingsGo(showingUpdate: true));
        unawaited(refreshUpdates(_facts.add));
      case 'battery_use':
        _go(context, const SettingsGo(showingUse: true));
        unawaited(_ask(context, () async => _facts.add(SettingsFacts(energy: Change(await VrxEnergy.service.energy())))));
      case 'why_awake':
        _go(context, const SettingsGo(showingAwake: true));
        unawaited(_ask(context, () async {
          final awake = await VrxEnergy.service.awake();
          final energy = model.energy ?? await VrxEnergy.service.energy(hours: 1);
          _facts.add(SettingsFacts(awake: Change(awake), energy: Change(energy)));
        }));
      case 'light_off':
        unawaited(_ask(context, () => _screen.setLightOff(model.nextLightOff)));
      case 'sleep_after':
        unawaited(_ask(context, () => _screen.setSleepAfter(model.nextSleepAfter)));
      case 'deep_after':
        unawaited(_ask(context, () => _screen.setDeepAfter(model.nextDeepAfter)));
      case 'reduce_motion':
        unawaited(_ask(context, () => _screen.setReduceMotion(on: !model.display.reduceMotion)));
      case 'on_screen_keyboard':
        unawaited(_ask(context, () => _screen.setKeyboard(nextKeyboardMode(model.display.keyboard))));
      case 'scheme':
        _go(context, const SettingsGo(pickingScheme: true));
      case 'polarity':
        unawaited(_setSetting('vrx', 'polarity', row.on ? 'light' : 'dark'));
      case 'time_format':
        _go(context, const SettingsGo(pickingTimeFormat: true));
      case 'set_date':
        _go(context, const SettingsGo(settingTime: SettingTime.date));
      case 'set_time':
        _go(context, const SettingsGo(settingTime: SettingTime.time));
      case 'automatic':
        unawaited(_ask(context, () => VrxSystem.time.setAutomatic(!row.on)));
      case 'zone':
        _go(context, const SettingsGo(pickingZone: true));
        if (model.zones.isEmpty) {
          unawaited(_ask(context, () async => _facts.add(SettingsFacts(zones: await VrxSystem.time.zones()))));
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

/// Pairing with a home app (plan 0015 D9): the QR code a home app scans,
/// the manual code for one that asks for it, and when the window closes.
class MatterPairing extends StatelessWidget {
  const MatterPairing({super.key, required this.state, required this.payload, required this.onBack, required this.onClose});

  final MatterState? state;
  final MatterPayload? payload;
  final VoidCallback onBack;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final space = ScaledSpacing.of(context);
    final p = payload;
    final until = state?.windowUntil;
    // the code is as wide as the panel allows, never taller than half of it
    final side = MediaQuery.sizeOf(context).shortestSide * 0.6;
    return VrxList(children: [
      VrxHeader(title: 'Pair with a home app', onBack: onBack),
      Padding(
        padding: EdgeInsets.all(space.inset),
        child: Text(
          p == null ? 'Opening…' : 'In the home app, add a device and scan this code, or type the code below.',
          style: TypeRole.body(context),
        ),
      ),
      if (p != null) ...[
        Center(child: SizedBox.square(dimension: side, child: VrxQr(data: p.qr, label: 'The code that pairs this device'))),
        VrxRow(label: 'Code', value: p.pretty),
        // where the board has Bluetooth and its radio is on (plan 0015 D4, D5)
        if (state?.ble ?? false) const VrxRow(label: 'Nearby phones', value: 'Over Bluetooth too'),
        if (until != null)
          VrxRow(label: 'Open until', value: '${until.hour.toString().padLeft(2, '0')}:${until.minute.toString().padLeft(2, '0')}'),
        VrxRow(label: 'Stop pairing', value: '', onTap: onClose),
      ],
    ]);
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
    SettingsCategory.matter: 'Matter',
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
          RowKind.toggle => VrxRow(label: row.label, value: row.value, widestValue: row.widest, onTap: () => onRow(row)),
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
  void fact(SettingsFacts f) => _facts.add(f);
  void failed(Object err) => fact(SettingsFacts(error: VrxWords.of(err, context: 'settings')));

  // each service on its own: one that is absent (a desktop run) leaves
  // the others working
  VrxSystem.time.watch().listen((t) => fact(SettingsFacts(time: t)), onError: failed);
  VrxSystem.network.watch().listen((n) => fact(SettingsFacts(network: n)), onError: failed);
  VrxSystem.device.watch().listen((d) => fact(SettingsFacts(device: d)), onError: failed);
  _screen.watch().listen((s) => fact(SettingsFacts(screen: s)), onError: failed);
  unawaited(_screen.dimming().then((d) => fact(SettingsFacts(dimming: d))));
  unawaited(_screen.cascade().then((c) => fact(SettingsFacts(cascade: c))));
  VrxSystem.power.watchSupplyLow().listen((low) => fact(SettingsFacts(supplyLow: low)), onError: failed);
  VrxSystem.usb.watch().listen((u) => fact(SettingsFacts(usbPresent: u.present)), onError: failed);
  VrxSystem.bluetooth.watch().listen((b) => fact(SettingsFacts(bluetooth: b)), onError: failed);
  VrxSystem.powerSupply.watch().listen((b) => fact(SettingsFacts(battery: Change(b))), onError: failed);
  unawaited(deviceUsage().then((u) => fact(SettingsFacts(usage: u))));
  // vrxhost's energy estimate (plan 0012 D12): on a device with vrxhost
  if (AppletsService.installed != null) fact(const SettingsFacts(energyAvailable: true));
  // software update (plan 0016 D11): where vrxhost answers for it
  if (AppletsService.installed != null) unawaited(findUpdates(fact));
  // the locales a time format can come from, and LC_TIME now (localed)
  unawaited(() async {
    try {
      final locales = await VrxSystem.locale.timeLocales();
      final now = await VrxSystem.locale.timeLocale();
      fact(SettingsFacts(timeLocales: locales, timeLocale: now));
    } on Object catch (err) {
      debugPrint('settings: no locales: $err');
    }
  }());
  // the look this boot draws, from the same snapshot every applet reads
  final boot = bootColors();
  fact(SettingsFacts(runningScheme: boot.scheme, runningDark: boot.dark));
  // the system's own settings (the chosen look)
  _settings.watch('vrx').listen((v) => fact(SettingsFacts(values: ('vrx', v))), onError: failed);
  // applets' declared settings, each file watched so a change shows
  unawaited(() async {
    final service = AppletsService.installed;
    if (service == null) return;
    try {
      final declared = await service.settings();
      fact(SettingsFacts(declared: declared));
      for (final a in declared) {
        _settings.watch(a.id).listen((v) => fact(SettingsFacts(values: (a.id, v))), onError: failed);
      }
    } on Object catch (err) {
      failed(err);
    }
  }());
  // Matter (plan 0015 D9): where the image carries vrx-matter
  final matter = await VrxMatter.find();
  if (matter != null) {
    matter.watch().listen((m) => fact(SettingsFacts(matter: m)), onError: (Object err) => debugPrint('settings: matter: $err'));
    unawaited(() async {
      try {
        fact(SettingsFacts(matterApplets: await matter.applets()));
      } on Object catch (err) {
        debugPrint('settings: matter applets: $err');
      }
    }());
  }
  try {
    final canOff = await VrxSystem.power.canPowerOff();
    fact(SettingsFacts(canPowerOff: canOff));
  } on Object catch (err) {
    failed(err);
  }
}
