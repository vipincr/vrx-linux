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

  @override
  bool get followsRoutes => true;

  @override
  SetupAction? onRoute(String route, Object? payload) => SetupOpened(route);

  Future<void> _finish() async {
    _events.add(const SetupFinish(done: false));
    try {
      await VrxSystem.device.setName(model.name.trim());
      if (model.zone.isNotEmpty) await VrxSystem.time.setZone(model.zone);
      await File(_done).writeAsString('${DateTime.now().toIso8601String()}\n');
      _events.add(const SetupFinish(done: true));
      // set up again from Settings: back there; the first boot: Home
      unawaited(model.again ? Nav.pop() : Nav.home());
    } on Object catch (err) {
      _events.add(SetupFinish(done: true, error: VrxWords.of(err, context: 'setup: finish')));
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
          onNext: () => _events.add(SetupAction.next),
          nextLabel: 'Accept',
        ),
      SetupStep.name => VrxTextEntry(
          title: 'Device name',
          initial: model.name,
          hint: 'Kitchen display',
          helper: (text) => 'Network name: ${hostnameFor(text)}',
          error: view.error,
          onBack: () => _events.add(SetupAction.back),
          onDone: (text) => _events.add(SetupName(text)),
        ),
      SetupStep.wifi => VrxSetupStep(
          step: 3,
          of: 5,
          title: 'Network',
          intro: view.network.isEmpty ? 'Join a Wi-Fi network, or plug in a cable.' : 'Connected: ${view.network}',
          control: VrxChip(label: 'Choose a Wi-Fi network', onTap: () => Nav.push('wifi')),
          onNext: () => _events.add(SetupAction.next),
          nextLabel: view.network.isEmpty ? 'Skip' : 'Next',
        ),
      SetupStep.zone => VrxZonePicker(
          title: 'Time zone',
          zones: view.zones,
          current: view.zone,
          onBack: () => _events.add(SetupAction.back),
          onPick: (z) => _events.add(SetupPickZone(z)),
        ),
      SetupStep.done => VrxSetupStep(
          step: 5,
          of: 5,
          title: view.again ? 'Save your changes' : 'Ready',
          intro: '${view.name.trim()}${view.zone.isEmpty ? '' : ' · ${view.zone}'}',
          control: const SizedBox.shrink(),
          banner: view.error,
          onNext: view.finishing ? null : () => unawaited(_finish()),
          nextLabel: view.finishing ? 'Saving…' : (view.again ? 'Save' : 'Start'),
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
    _events.add(SetupFacts(
        network: wifi != null ? '${wifi.name} (${wifi.address})' : (n.wired ? 'Wired (${n.ethernetAddress})' : '')));
  }, onError: (Object _) {});
  VrxSystem.time.watch().listen((t) => _events.add(SetupFacts(zone: t.zone)), onError: (Object _) {});
  try {
    _events.add(SetupFacts(zones: await VrxSystem.time.zones()));
  } on Object catch (err) {
    _events.add(SetupFacts(error: VrxWords.of(err, context: 'setup: zones')));
  }
}
