import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' hide Intent; // vrx's Intent
import 'package:vrx_kit/vrx_kit.dart';

import 'state.dart';

final _events = StreamController<ManageAction>();

/// Manage (plan 0011 D15): opening it serves the management page and
/// leaving it stops it (vrx-manage.service, through Flutter's lifecycle);
/// the address is a QR code. With no network it hosts one (connman's
/// tethering), shows its QR code to join, then the address.
class ManageApplet extends Applet<bool, ManageAction, ManageView> {
  ManageApplet(this.model);

  final ManageModel model;

  @override
  bool get initial => model.initial;

  @override
  ManageAction get bootAction => model.bootAction;

  @override
  ManageView reduce(bool state, ManageAction action) => model.reduce(state, action);

  @override
  bool get snapshot => model.snapshot;

  @override
  String? get keepsScreenOn => model.keepsScreenOn;

  void serve(bool on) {
    if (!on) _events.add(ManageAction.askStop);
    unawaited(VrxSystem.manage.serve(on).catchError((Object err) {
      _events.add(ManageFacts(error: Change(VrxWords.of(err, context: 'manage: serve'))));
    }));
  }

  Future<void> host(bool on) async {
    final ssid = on ? hostedName(model.hostname) : model.ssid;
    final passphrase = on ? hostedPassphrase() : model.passphrase;
    try {
      await VrxSystem.network.host(on: on, ssid: ssid, passphrase: passphrase);
      _events.add(ManageHosted(on: on, ssid: ssid, passphrase: passphrase, address: on ? await tetherAddress() : ''));
    } on Object catch (err) {
      _events.add(ManageFacts(error: Change(VrxWords.of(err, context: 'manage: host'))));
    }
  }

  @override
  Widget build(BuildContext context, ManageView view) {
    final space = ScaledSpacing.of(context);
    final serving = view.serving == true;
    final first = view.addresses.isEmpty ? null : view.addresses.first;
    final words = switch (view.serving) {
      null => '…',
      true when view.hosting => 'Join this network on a phone, with the code or by its name and passphrase. Then open the address below.',
      true when view.onNoNetwork => 'This device is on no network. It can host one for a phone to join.',
      true => 'Open this address on a phone or computer on the same network.',
      false when view.stoppedIdle => 'The page stopped by itself after ten minutes in which nobody asked.',
      false => 'The page is not being served.',
    };
    // the code is as wide as the panel allows, never taller than half of it
    final qrSide = (MediaQuery.sizeOf(context).shortestSide * 0.6);
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: VrxList(children: [
              const VrxHeader(title: 'Manage', onBack: Nav.pop),
              Padding(padding: EdgeInsets.all(space.inset), child: Text(words, style: TypeRole.body(context))),
              if (serving && view.hosting) ...[
                Center(child: SizedBox.square(dimension: qrSide, child: VrxQr(data: view.wifiQr, label: 'The code that joins ${view.ssid}'))),
                VrxRow(label: 'Network', value: view.ssid),
                VrxRow(label: 'Passphrase', value: view.passphrase),
              ],
              if (serving && first != null && !view.onNoNetwork) ...[
                SizedBox(height: space.sm),
                Center(child: SizedBox.square(dimension: qrSide, child: VrxQr(data: first, label: 'The address of this page'))),
                for (final a in view.addresses) VrxRow(label: a),
              ],
            ]),
          ),
          // the one action stays in view; the words above scroll on a
          // panel too short for them (the 58mm disp28a)
          if (view.serving != null)
            Padding(
              padding: EdgeInsets.all(space.inset),
              child: SizedBox(
                width: double.infinity,
                child: switch ((serving, view.onNoNetwork, view.hosting)) {
                  (false, _, _) => VrxChip(label: view.stoppedIdle ? 'Start again' : 'Serve the page', filled: true, onTap: () => serve(true)),
                  (true, true, _) => VrxChip(label: 'Host a network', filled: true, onTap: () => unawaited(host(true))),
                  (true, _, true) => VrxChip(label: 'Stop hosting', onTap: () => unawaited(host(false))),
                  _ => VrxChip(label: 'Stop', onTap: () => serve(false)),
                },
              ),
            ),
          if (view.hosting) Padding(
            padding: EdgeInsets.symmetric(horizontal: space.inset),
            child: Text('While it hosts a network, the device is on no other.', style: TypeRole.caption(context)),
          ),
          if (view.error != null) VrxBanner(text: view.error),
        ]),
      ),
    );
  }
}

/// The hosted network's address: connman's tether bridge, as `ip` says.
Future<String> tetherAddress() async {
  try {
    final r = await Process.run('ip', ['-4', '-o', 'addr', 'show', 'tether']);
    final m = RegExp(r'inet (\d+\.\d+\.\d+\.\d+)').firstMatch('${r.stdout}');
    return m?.group(1) ?? '';
  } on ProcessException {
    return '';
  }
}

void main() {
  final model = ManageModel();
  final applet = ManageApplet(model);
  runApplet(applet, actions: _events.stream);
  void failed(Object err) => _events.add(ManageFacts(error: Change(VrxWords.of(err, context: 'manage'))));

  VrxSystem.manage.watch().listen((on) => _events.add(ManageFacts(serving: on)), onError: failed);
  VrxSystem.device.watch().listen((d) => _events.add(ManageFacts(hostname: d.hostname)), onError: failed);
  VrxSystem.network.watch().listen(
      (n) => _events.add(ManageFacts(ips: [if (n.wired) n.ethernetAddress, if (n.connected != null) n.connected!.address])),
      onError: failed);
  // opening serves the page; leaving (Back, Home, another applet in
  // front) stops it, and the hosted network with it
  applet.serve(true);
  AppLifecycleListener(
    onShow: () => applet.serve(true),
    onHide: () {
      applet.serve(false);
      if (model.hosting) unawaited(applet.host(false));
    },
  );
}
