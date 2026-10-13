import 'dart:async';

import 'package:flutter/material.dart' hide Intent; // vrx's Intent
import 'package:vrx_kit/vrx_kit.dart';

import 'state.dart';

final _events = StreamController<UsbAction>();

/// USB: share files with the computer on the board's device port.
class UsbApplet extends Applet<UsbState, UsbAction, UsbView> {
  UsbApplet(this.model);

  final UsbModel model;

  @override
  UsbState get initial => model.initial;

  @override
  UsbAction get bootAction => model.bootAction;

  @override
  UsbView reduce(UsbState state, UsbAction action) => model.reduce(state, action);

  @override
  UsbState get snapshot => model.snapshot;

  void _share(bool on) => unawaited(VrxSystem.usb.share(on).catchError((Object err) {
        model.error = VrxWords.of(err, context: 'usbport: share');
        _events.add(UsbAction.failed);
      }));

  @override
  Widget build(BuildContext context, UsbView view) {
    final space = ScaledSpacing.of(context);
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: VrxList(children: [
              VrxHeader(title: view.title, onBack: Nav.pop),
              Padding(
                padding: EdgeInsets.all(space.inset),
                child: Text(view.message, style: TypeRole.body(context)),
              ),
            ]),
          ),
          // the one action stays in view; the words above scroll on a
          // panel too short for them (the 58mm disp28a)
          if (view.offer != UsbOffer.none)
            Padding(
              padding: EdgeInsets.all(space.inset),
              child: SizedBox(
                width: double.infinity,
                child: view.offer == UsbOffer.share
                    ? VrxChip(label: 'Share files', filled: true, onTap: () => _share(true))
                    : VrxChip(label: 'Stop sharing', filled: true, onTap: () => _share(false)),
              ),
            ),
          if (view.error != null) VrxBanner(text: view.error),
        ]),
      ),
    );
  }
}

void main() {
  final model = UsbModel();
  runApplet(UsbApplet(model), actions: _events.stream);
  VrxSystem.usb.watch().listen((u) {
    model.usb = u;
    _events.add(UsbAction.factsChanged);
  }, onError: (Object err) {
    model.error = VrxWords.of(err, context: 'usbport: watch');
    _events.add(UsbAction.failed);
  });
}
