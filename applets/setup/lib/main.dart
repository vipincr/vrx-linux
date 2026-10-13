import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' hide Intent; // vrx's Intent
import 'package:vrx_kit/vrx_kit.dart';

import 'state.dart';

/// The marker vrxhost looks for: Setup's own state directory, so a
/// factory reset (wiping /data) brings the walk back.
const _done = '/var/lib/vrx/setup/done';

final _events = StreamController<SetupAction>();

/// Setup: licence, name, Wi-Fi, time zone, done. The name and zone are
/// written at the end, through hostnamed and timedated; Wi-Fi is the
/// Wi-Fi applet (a trail push), so joining a network is one code path.
class SetupApplet extends Applet<SetupState, SetupAction, SetupView> {
  SetupApplet(this.model);

  final SetupModel model;

  @override
  SetupState get initial => model.initial;

  @override
  SetupAction get bootAction => model.bootAction;

  @override
  SetupView reduce(SetupState state, SetupAction action) => model.reduce(state, action);

  @override
  SetupState get snapshot => model.snapshot;

  void _move(void Function() change) {
    change();
    _events.add(SetupAction.moved);
  }

  Future<void> _finish() async {
    _move(() => model.finishing = true);
    try {
      await VrxSystem.device.setName(model.name.trim());
      if (model.zone.isNotEmpty) await VrxSystem.time.setZone(model.zone);
      await File(_done).writeAsString('${DateTime.now().toIso8601String()}\n');
      model.finishing = false;
      Nav.home();
    } on Object catch (err) {
      model
        ..finishing = false
        ..error = err is SystemError ? err.message : '$err';
      _events.add(SetupAction.failed);
    }
  }

  @override
  Widget build(BuildContext context, SetupView view) {
    final Widget body = switch (view.step) {
      SetupStep.licence => VrxSetupStep(
          step: 1,
          of: 5,
          title: 'Welcome',
          intro: 'This device runs vrx and open source software. Their licences come with it.',
          control: VrxChip(label: 'Read the licences', onTap: () => Nav.push('docs')),
          onNext: () => _move(model.next),
          nextLabel: 'Accept',
        ),
      SetupStep.name => VrxTextEntry(
          title: 'Device name',
          initial: model.name,
          hint: 'Kitchen display',
          helper: (text) => 'Network name: ${hostnameFor(text)}',
          error: view.error,
          onBack: () => _move(model.back),
          onDone: (text) {
            model.name = text;
            if (!model.canLeaveName) {
              model.error = 'The device needs a name';
              _events.add(SetupAction.failed);
              return;
            }
            _move(model.next);
          },
        ),
      SetupStep.wifi => VrxSetupStep(
          step: 3,
          of: 5,
          title: 'Network',
          intro: view.network.isEmpty ? 'Join a Wi-Fi network, or plug in a cable.' : 'Connected: ${view.network}',
          control: VrxChip(label: 'Choose a Wi-Fi network', onTap: () => Nav.push('wifi')),
          onNext: () => _move(model.next),
          nextLabel: view.network.isEmpty ? 'Skip' : 'Next',
        ),
      SetupStep.zone => VrxZonePicker(
          title: 'Time zone',
          zones: view.zones,
          current: view.zone,
          onBack: () => _move(model.back),
          onPick: (z) => _move(() {
            model.zone = z;
            model.next();
          }),
        ),
      SetupStep.done => VrxSetupStep(
          step: 5,
          of: 5,
          title: 'Ready',
          intro: '${view.name.trim()}${view.zone.isEmpty ? '' : ' · ${view.zone}'}',
          control: const SizedBox.shrink(),
          banner: view.error,
          onNext: view.finishing ? null : () => unawaited(_finish()),
          nextLabel: view.finishing ? 'Saving…' : 'Start',
        ),
    };
    return Scaffold(body: SafeArea(child: body));
  }
}

Future<void> main() async {
  final model = SetupModel();
  runApplet(SetupApplet(model), actions: _events.stream);
  VrxSystem.network.watch().listen((n) {
    final wifi = n.connected;
    model.network = wifi != null
        ? '${wifi.name} (${wifi.address})'
        : (n.wired ? 'Wired (${n.ethernetAddress})' : '');
    _events.add(SetupAction.factsChanged);
  }, onError: (Object _) {});
  VrxSystem.time.watch().listen((t) {
    if (model.zone.isEmpty) model.zone = t.zone;
    _events.add(SetupAction.factsChanged);
  }, onError: (Object _) {});
  try {
    model.zones = await VrxSystem.time.zones();
    _events.add(SetupAction.zonesLoaded);
  } on Object catch (err) {
    model.error = '$err';
    _events.add(SetupAction.failed);
  }
}
