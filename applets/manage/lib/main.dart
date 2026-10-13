import 'dart:async';

import 'package:flutter/material.dart' hide Intent; // vrx's Intent
import 'package:vrx_kit/vrx_kit.dart';

import 'state.dart';

final _events = StreamController<ManageAction>();

/// Manage: serve the management page to a browser on the same network.
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

  void _serve(bool on) => unawaited(VrxSystem.manage.serve(on).catchError((Object err) {
        model.error = err is SystemError && err.denied ? 'This applet may not serve the page (the serve grant)' : '$err';
        _events.add(ManageAction.failed);
      }));

  @override
  Widget build(BuildContext context, ManageView view) {
    final space = ScaledSpacing.of(context);
    final serving = view.serving == true;
    final words = switch (view.serving) {
      null => '…',
      true => 'A browser on the same network opens the page at:',
      false => 'Serve this device\'s page to a browser on the same network. It stops by itself after ten minutes in which nobody asks.',
    };
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: VrxList(children: [
              const VrxHeader(title: 'Manage', onBack: Nav.pop),
              Padding(padding: EdgeInsets.all(space.inset), child: Text(words, style: TypeRole.body(context))),
              if (serving)
                for (final a in view.addresses) VrxRow(label: a),
            ]),
          ),
          // the one action stays in view; the words above scroll on a
          // panel too short for them (the 58mm disp28a)
          if (view.serving != null)
            Padding(
              padding: EdgeInsets.all(space.inset),
              child: SizedBox(
                width: double.infinity,
                child: VrxChip(label: serving ? 'Stop' : 'Serve the page', filled: true, onTap: () => _serve(!serving)),
              ),
            ),
          if (view.error != null) VrxBanner(text: view.error),
        ]),
      ),
    );
  }
}

void main() {
  final model = ManageModel();
  runApplet(ManageApplet(model), actions: _events.stream);
  void fact(void Function() change) {
    change();
    _events.add(ManageAction.factsChanged);
  }

  void failed(Object err) {
    model.error = '$err';
    _events.add(ManageAction.failed);
  }

  VrxSystem.manage.watch().listen((on) => fact(() => model.serving = on), onError: failed);
  VrxSystem.device.watch().listen((d) => fact(() => model.hostname = d.hostname), onError: failed);
  VrxSystem.network.watch().listen(
      (n) => fact(() => model.ips = [if (n.wired) n.ethernetAddress, if (n.connected != null) n.connected!.address]),
      onError: failed);
}
