/// Device Link: pair a phone with this device over Bluetooth (plan 0011
/// D19, plan 0008 Part H). Linux first: connman turns the radio on, BlueZ
/// pairs and keeps the bonds; this applet is BlueZ's agent while its
/// window is open, so the passkey is on this screen and a person answers
/// Pair or Cancel. No tile: Settings > Device opens it, and so does the
/// drawer's Bluetooth button.
///
/// The phone companion's GATT protocol (evrx-rt's ble_link service) is
/// not here: it is a separate approval (plan 0011 D19).
library;

import 'dart:async';

import 'package:flutter/material.dart' hide Intent; // vrx's Intent
import 'package:vrx_kit/vrx_kit.dart';

import 'state.dart';

final _events = StreamController<LinkAction>();

class LinkApplet extends Applet<Object, LinkAction, LinkView> {
  LinkApplet(this.model, {StreamController<LinkAction>? events}) : _out = events ?? _events;

  final LinkModel model;

  /// Where its own actions go: the applet's stream, or a test's.
  final StreamController<LinkAction> _out;

  @override
  Object get initial => model.initial;

  @override
  LinkAction get bootAction => model.bootAction;

  @override
  LinkView reduce(Object state, LinkAction action) => model.reduce(state, action);

  @override
  Object get snapshot => model.snapshot;

  void _do(Future<void> Function() act, {String context = 'devicelink', LinkAction? then}) =>
      unawaited(act().then((_) {
        if (then != null) _out.add(then);
      }).catchError((Object err) {
        _out.add(LinkFacts(error: Change(VrxWords.of(err, context: context))));
      }));

  void _openPairing(LinkView view) {
    if (!view.on) _out.add(const LinkFacts(notice: Change('Bluetooth is on now.')));
    _do(() => VrxSystem.bluetooth.openPairing(confirm: _confirm), context: 'devicelink: pair', then: LinkAction.pairingOpened);
  }

  /// A phone asked: the question is a screen of its own until answered,
  /// or until BlueZ cancels it (the phone gave up).
  Future<bool> _confirm(BluetoothPairing request) {
    final answer = Completer<bool>();
    void settle(bool pair) {
      if (answer.isCompleted) return;
      answer.complete(pair);
      _out.add(LinkAction.answered);
    }

    _out.add(LinkAsked(request, settle));
    unawaited(request.canceled.then((_) => settle(false)));
    return answer.future;
  }

  Future<void> _confirmForget(BuildContext context, BluetoothDevice device) async {
    final yes = await vrxConfirm(
      context,
      title: 'Forget ${device.name}?',
      message: 'It has to pair again before it can connect.',
      act: 'Forget',
    );
    if (!yes) return;
    _do(() => VrxSystem.bluetooth.forget(device.id), context: 'devicelink: forget', then: LinkAction.deviceClosed);
  }

  @override
  Widget build(BuildContext context, LinkView view) {
    final space = ScaledSpacing.of(context);
    final body = switch (view.screen) {
      LinkScreen.asking => _Asking(view: view, onAnswer: (pair) => model.answer?.call(pair)),
      LinkScreen.device => _Device(
          device: view.device!,
          onBack: () => _out.add(LinkAction.deviceClosed),
          onForget: () => _confirmForget(context, view.device!),
        ),
      LinkScreen.main => ListView(children: [
          const VrxHeader(title: 'Device Link', onBack: Nav.pop),
          if (view.status.isNotEmpty)
            Padding(
              padding: EdgeInsets.all(space.inset),
              child: Text(view.status, style: TypeRole.body(context)),
            ),
          if (view.usable) ...[
            VrxRow(
              glyph: view.on ? VrxSymbols.bluetooth : VrxSymbols.bluetooth_disabled,
              label: 'Bluetooth',
              value: view.on ? 'On' : 'Off',
              onTap: () => _do(() => VrxSystem.bluetooth.setOn(!view.on), context: 'devicelink: power'),
            ),
            if (view.pairing)
              VrxRow(
                glyph: VrxSymbols.bluetooth_searching,
                label: 'Stop pairing',
                detail: view.pairDetail,
                value: '',
                onTap: () => _do(VrxSystem.bluetooth.closePairing, context: 'devicelink: close', then: LinkAction.pairingClosed),
              )
            else
              VrxRow(glyph: VrxSymbols.add, label: 'Pair a phone', value: '', onTap: () => _openPairing(view)),
            if (view.devices.isNotEmpty) const VrxSection(title: 'Paired'),
            for (final d in view.devices)
              VrxRow(
                glyph: d.connected ? VrxSymbols.bluetooth_connected : VrxSymbols.smartphone,
                label: d.name,
                value: d.connected ? 'Connected' : '',
                onTap: () => _out.add(LinkOpenDevice(d.id)),
              ),
          ],
        ]),
    };
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          Expanded(child: body),
          // VrxBanner owns its exit (DS-01): the error, else the
          // notice, mounted unguarded so the slide-out runs
          VrxBanner(
            text: view.error ?? (view.screen == LinkScreen.main ? view.notice : null),
            signal: view.error != null ? VrxSignal.error : VrxSignal.info,
          ),
        ]),
      ),
    );
  }
}

/// A phone asking to pair: the number both screens show, and the answer.
class _Asking extends StatelessWidget {
  const _Asking({required this.view, required this.onAnswer});

  final LinkView view;
  final void Function(bool pair) onAnswer;

  @override
  Widget build(BuildContext context) {
    final space = ScaledSpacing.of(context);
    return Column(children: [
      Expanded(
        child: ListView(children: [
          // Back is Cancel: the question is answered either way
          VrxHeader(title: 'Pair with ${view.askingName}?', onBack: () => onAnswer(false)),
          Padding(
            padding: EdgeInsets.all(space.inset),
            child: Text(view.status, style: TypeRole.body(context)),
          ),
          if (view.passkey != null)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: space.inset, vertical: space.md),
              child: VrxFitText(view.passkey!, style: TypeRole.display(context), widest: '888 888', maxLines: 1),
            ),
        ]),
      ),
      // the answer stays in view: Cancel first, the act last and filled
      Padding(
        padding: EdgeInsets.all(space.inset),
        child: Row(children: [
          Expanded(child: VrxChip(label: 'Cancel', fit: true, onTap: () => onAnswer(false))),
          SizedBox(width: space.md),
          Expanded(child: VrxChip(label: 'Pair', filled: true, fit: true, onTap: () => onAnswer(true))),
        ]),
      ),
    ]);
  }
}

/// One paired device's screen: what BlueZ says about it, and Forget.
class _Device extends StatelessWidget {
  const _Device({required this.device, required this.onBack, required this.onForget});

  final BluetoothDevice device;
  final VoidCallback onBack;
  final VoidCallback onForget;

  @override
  Widget build(BuildContext context) {
    return ListView(children: [
      VrxHeader(title: device.name, onBack: onBack),
      VrxRow(
        glyph: device.connected ? VrxSymbols.bluetooth_connected : VrxSymbols.bluetooth,
        label: 'Status',
        value: device.connected ? 'Connected' : 'Paired',
      ),
      VrxRow(label: 'Forget this phone', value: '', onTap: onForget),
    ]);
  }
}

void main() {
  final model = LinkModel();
  runApplet(LinkApplet(model), actions: _events.stream);
  VrxSystem.bluetooth.watch().listen((b) => _events.add(LinkFacts(bt: b)),
      onError: (Object err) => _events.add(LinkFacts(error: Change(VrxWords.of(err, context: 'devicelink: watch')))));
  // 12 or 24 hours for the window's end: the system's locale
  final format = VrxTimeFormat.changes;
  void follow() => _events.add(LinkFacts(h24: format.value));

  follow();
  format.addListener(follow);
}
