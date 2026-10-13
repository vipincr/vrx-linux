import 'dart:async';

import 'package:flutter/material.dart' hide Intent; // vrx's Intent
import 'package:vrx_kit/vrx_kit.dart';

import 'state.dart';

final _events = StreamController<WifiAction>();

/// Wi-Fi: connman's networks, joined through connman. A secured network
/// connman has no passphrase for asks through its agent; this applet
/// answers with the passphrase screen (the on-screen keyboard).
class WifiApplet extends Applet<WifiState, WifiAction, WifiView> {
  WifiApplet(this.model);

  final WifiModel model;
  final _passphrase = TextEditingController();
  Completer<String?>? _answer;

  @override
  WifiState get initial => model.initial;

  @override
  WifiAction get bootAction => model.bootAction;

  @override
  WifiView reduce(WifiState state, WifiAction action) => model.reduce(state, action);

  @override
  WifiState get snapshot => model.snapshot;

  Future<void> _ask(Future<void> Function() call) async {
    try {
      await call();
    } on SystemError catch (err) {
      model.error = _phrase(err);
      _events.add(WifiAction.failed);
    } on Object catch (err) {
      model.error = '$err';
      _events.add(WifiAction.failed);
    }
  }

  /// connman's error names, said for a person.
  static String _phrase(SystemError err) {
    if (err.denied) return 'Not allowed to change the network';
    if (err.name.endsWith('InvalidKey') || err.message.contains('invalid-key')) return 'Wrong passphrase';
    if (err.name.endsWith('Canceled') || err.name.endsWith('OperationAborted')) return 'Canceled';
    if (err.name.endsWith('AlreadyConnected')) return 'Already connected';
    return err.message.isEmpty ? err.name : err.message;
  }

  void _join(WifiNetwork network) {
    unawaited(_ask(() => VrxSystem.network.connect(
          network.id,
          passphrase: (_) {
            // connman's agent asks: show the screen, wait for done or back
            _passphrase.clear();
            model.asking = network;
            _events.add(WifiAction.asked);
            return (_answer = Completer<String?>()).future;
          },
        )));
  }

  void _answerWith(String? passphrase) {
    model.asking = null;
    _events.add(WifiAction.asked);
    _answer?.complete(passphrase);
    _answer = null;
  }

  @override
  Widget build(BuildContext context, WifiView view) {
    final asking = view.asking;
    return Scaffold(
      body: SafeArea(
        child: asking != null
            ? _PassphraseScreen(
                network: asking,
                controller: _passphrase,
                onBack: () => _answerWith(null),
                onDone: () => _answerWith(_passphrase.text),
              )
            : Column(children: [
                Expanded(child: _Networks(view: view, onJoin: _join, onForget: (n) => _confirmForget(context, n))),
                if (view.error != null) VrxBanner(text: view.error),
              ]),
      ),
    );
  }

  void _confirmForget(BuildContext context, WifiNetwork network) {
    unawaited(showDialog<void>(
      context: context,
      builder: (dialog) => VrxConfirm(
        title: 'Forget ${network.name}?',
        message: 'Its passphrase is deleted and the device stops joining it.',
        cancelLabel: 'Cancel',
        onCancel: () => Navigator.of(dialog).pop(), // vrx-allow: a dialog's own route, not the trail
        act: VrxModalAction(
          label: 'Forget',
          onTap: () {
            Navigator.of(dialog).pop(); // vrx-allow: a dialog's own route, not the trail
            unawaited(_ask(() => VrxSystem.network.forget(network.id)));
          },
        ),
      ),
    ));
  }
}

class _Networks extends StatelessWidget {
  const _Networks({required this.view, required this.onJoin, required this.onForget});

  final WifiView view;
  final void Function(WifiNetwork) onJoin;
  final void Function(WifiNetwork) onForget;

  @override
  Widget build(BuildContext context) {
    final connected = view.connected;
    final nearby = view.on ? view.nearby : const <WifiNetwork>[];
    return CustomScrollView(slivers: [
      SliverList.list(children: [
        const VrxHeader(title: 'Wi-Fi', onBack: Nav.pop),
        if (!view.present)
          const VrxRow(label: 'This device has no Wi-Fi', value: '')
        else ...[
          VrxSettingRow(
            label: 'Wi-Fi',
            value: view.on ? 'On' : 'Off',
            onTap: () => unawaited(VrxSystem.network.setWifi(!view.on).catchError((Object _) {})),
          ),
          if (connected != null)
            VrxRow(
              glyph: VrxSymbols.named(signalGlyph(connected.strength)),
              label: connected.name,
              value: view.address.isEmpty ? 'Connected' : view.address,
              onTap: () => onForget(connected),
            ),
          if (view.on) const VrxSection(title: 'Nearby'),
        ],
      ]),
      // dozens of networks in a busy place: built as they scroll in
      SliverList.builder(
        itemCount: nearby.length,
        itemBuilder: (context, i) {
          final n = nearby[i];
          return VrxRow(
            glyph: VrxSymbols.named(signalGlyph(n.strength)),
            label: n.name,
            value: n.connecting ? 'Joining…' : n.saved ? 'Saved' : (n.secured ? '🔒' : ''),
            onTap: () => n.saved ? onForget(n) : onJoin(n),
          );
        },
      ),
      if (view.present && view.on)
        SliverToBoxAdapter(
          child: VrxRow(
            label: 'Scan again',
            value: '',
            onTap: () => unawaited(VrxSystem.network.scan().catchError((Object _) {})),
          ),
        ),
    ]);
  }
}

class _PassphraseScreen extends StatelessWidget {
  const _PassphraseScreen({
    required this.network,
    required this.controller,
    required this.onBack,
    required this.onDone,
  });

  final WifiNetwork network;
  final TextEditingController controller;
  final VoidCallback onBack;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final space = ScaledSpacing.of(context);
    return Column(children: [
      VrxHeader(title: network.name, onBack: onBack),
      Padding(
        padding: EdgeInsets.all(space.md),
        child: TextField(
          controller: controller,
          readOnly: true, // typed on the keyboard below, not an IME
          showCursor: true,
          autofocus: true,
          obscureText: false,
          style: TypeRole.body(context),
          decoration: const InputDecoration(labelText: 'Passphrase'),
        ),
      ),
      const Spacer(),
      VrxKeyboard(controller: controller, onDone: onDone),
    ]);
  }
}

Future<void> main() async {
  final model = WifiModel();
  runApplet(WifiApplet(model), actions: _events.stream);
  VrxSystem.network.watch().listen((n) {
    model.network = n;
    _events.add(WifiAction.networkChanged);
  }, onError: (Object err) {
    model.error = '$err';
    _events.add(WifiAction.failed);
  });
  // a fresh list on open: connman's own is from its last scan
  try {
    await VrxSystem.network.scan();
  } on Object catch (_) {
    // the list above still shows connman's last scan
  }
}
