import 'dart:async';

import 'package:flutter/material.dart' hide Intent; // vrx's Intent
import 'package:vrx_kit/vrx_kit.dart';

import 'state.dart';

/// Facts from the system services, for the applet's whole life.
final _facts = StreamController<SettingsAction>();

/// The settings applet: the system's own settings, each row bound to the
/// Linux service that owns it (plan 0008 Part D): time and zone through
/// timedated, the device name through hostnamed, power through logind,
/// the light through the backlight. A tap asks the service; the row
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

  void _go(BuildContext context, void Function() change) {
    change();
    AppletScope.dispatch(context, SettingsAction.navigated);
  }

  Future<void> _ask(BuildContext context, Future<void> Function() call) async {
    try {
      await call();
    } on SystemError catch (err) {
      model.error = err.denied ? 'Not allowed: ${err.message}' : err.message;
      _facts.add(SettingsAction.failed);
    } on Object catch (err) {
      model.error = '$err';
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

  void _onRow(BuildContext context, SettingRow row) {
    switch (row.key) {
      case 'wifi':
      case 'setup':
        // their own applets (no tile): a trail push, vrxhost starts them
        Nav.push(row.key);
      case 'licences':
        Nav.push('docs');
      case 'name':
        _go(context, () => model.renaming = true);
      case 'light':
        unawaited(_ask(context, () => VrxSystem.power.setLight(!row.on)));
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
        unawaited(showDialog<void>(
          context: context,
          builder: (dialog) => VrxConfirm(
            title: off ? 'Power off?' : 'Restart?',
            message: off
                ? 'The device turns off. It starts again when its power button or supply says so.'
                : 'Every applet closes and the device starts again.',
            cancelLabel: 'Cancel',
            onCancel: () => Navigator.of(dialog).pop(), // vrx-allow: a dialog's own route, not the trail
            act: VrxModalAction(
              label: off ? 'Power off' : 'Restart',
              onTap: () {
                Navigator.of(dialog).pop(); // vrx-allow: a dialog's own route, not the trail
                unawaited(_ask(context, off ? VrxSystem.power.powerOff : VrxSystem.power.reboot));
              },
            ),
          ),
        ));
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
  });

  final SettingsView view;
  final SettingsCategory category;
  final VoidCallback onBack;
  final void Function(SettingRow) onRow;

  static const _titles = {
    SettingsCategory.display: 'Display',
    SettingsCategory.power: 'Power',
    SettingsCategory.time: 'Time',
    SettingsCategory.network: 'Network',
    SettingsCategory.device: 'Device',
  };

  @override
  Widget build(BuildContext context) {
    return VrxList(children: [
      // back within the applet: the category list
      VrxHeader(title: _titles[category] ?? '', onBack: onBack),
      for (final row in view.rows)
        switch (row.kind) {
          RowKind.toggle => VrxRow(
              label: row.label,
              value: row.on ? 'On' : 'Off',
              onTap: () => onRow(row),
            ),
          RowKind.open => VrxRow(label: row.label, value: '${row.value}  ›', onTap: () => onRow(row)),
          RowKind.confirm => VrxRow(label: row.label, value: '', onTap: () => onRow(row)),
          RowKind.info => VrxRow(label: row.label, value: row.value),
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
    model.error = '$err';
    _facts.add(SettingsAction.failed);
  }

  // each service on its own: one that is absent (a desktop run, a board
  // without a backlight) leaves the others working
  VrxSystem.time.watch().listen((t) => fact(() => model.time = t), onError: failed);
  VrxSystem.network.watch().listen((n) => fact(() => model.network = n), onError: failed);
  VrxSystem.device.watch().listen((d) => fact(() => model.device = d), onError: failed);
  VrxSystem.power.watchLight().listen((on) => fact(() => model.light = on), onError: failed);
  try {
    final levels = await VrxSystem.power.lightLevels();
    final canOff = await VrxSystem.power.canPowerOff();
    fact(() {
      model.lightLevels = levels;
      model.canPowerOff = canOff;
    });
  } on Object catch (err) {
    failed(err);
  }
}
