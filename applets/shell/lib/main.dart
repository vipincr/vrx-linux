import 'dart:async';

import 'package:flutter/material.dart' hide Intent; // vrx's Intent
import 'package:vrx_kit/vrx_kit.dart';

import 'state.dart';

final _events = StreamController<ShellAction>();

/// The shell: the status strip, and the quick drawer a tap on it opens.
class ShellApplet extends Applet<ShellState, ShellAction, ShellView> {
  ShellApplet(this.model);

  final ShellModel model;

  @override
  ShellState get initial => model.initial;

  @override
  ShellAction get bootAction => model.bootAction;

  @override
  ShellView reduce(ShellState state, ShellAction action) => model.reduce(state, action);

  @override
  ShellState get snapshot => model.snapshot;

  void _toggle() => _events.add(ShellAction.drawerToggled);

  @override
  Widget build(BuildContext context, ShellView view) {
    final facts = VrxStatusFacts(
      showBack: view.canGoBack,
      // the one Back: the focused app goes back a screen, or leaves
      onBack: () => unawaited(VrxShell.back()),
      clockText: view.facts.clockText,
      dateText: view.facts.dateText,
      wifiUp: view.wifiUp,
    );
    // the compositor routes input by the strip's height, and gives the
    // shell all of it while the drawer is open
    final strip = VrxShellRegion(
      full: view.drawer,
      child: VrxPress(onTap: _toggle, child: VrxStatusStrip(facts: facts)),
    );
    // the drawer is an overlay of its own (a scrim and a panel) over the
    // strip and the screen below it. Below the strip the shell is clear:
    // its plane sits above the focused app, which shows through.
    return Scaffold(
      backgroundColor: const Color(0x00000000),
      body: SafeArea(
        child: Column(children: [
          strip,
          // the drawer opens under the strip: its scrim and panel fill
          // the rest of the screen
          if (view.drawer)
            Expanded(
              child: Stack(children: [
                VrxQuickDrawer(
                  version: view.version,
                  lightOn: view.lightOn,
                  onLightToggle: () => unawaited(VrxSystem.power.setLight(!view.lightOn).catchError((Object _) {})),
                  wifiUp: view.wifiUp,
                  bleUp: false,
                  onWifi: () {
                    _toggle();
                    Nav.push('wifi');
                  },
                  onDismiss: _toggle,
                ),
              ]),
            ),
        ]),
      ),
    );
  }
}

Future<void> main() async {
  final model = ShellModel();
  runApplet(ShellApplet(model), actions: _events.stream);
  void fact(void Function() change) {
    change();
    _events.add(ShellAction.factsChanged);
  }

  VrxSystem.time
      .watch()
      .listen((t) => fact(() => model.clockValid = t.synced || DateTime.now().year >= 2025), onError: (Object _) {});
  VrxSystem.network.watch().listen((n) => fact(() => model.wifiUp = n.connected != null), onError: (Object _) {});
  VrxSystem.power.watchLight().listen((on) => fact(() => model.lightOn = on), onError: (Object _) {});
  // the release only ("0.1.0077"): the platform after it is Settings >
  // Device's, and wrapped three lines deep in the drawer
  VrxSystem.device.watch().listen(
      (d) => fact(() => model.version = d.version.isEmpty ? '' : 'vrx ${d.version.split(' ').first}'),
      onError: (Object _) {});
  AppletsService.installed?.watch().listen((f) => fact(() => model.depth = f.depth), onError: (Object _) {});
  // the strip's clock changes once a minute: a check every 10 s, a
  // repaint only when the minute turned
  var shown = '';
  Timer.periodic(const Duration(seconds: 10), (_) {
    if (model.clockText != shown) {
      shown = model.clockText;
      _events.add(ShellAction.factsChanged);
    }
  });
}
