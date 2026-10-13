import 'dart:async';

import 'package:flutter/material.dart' hide Intent; // vrx's Intent
import 'package:vrx_kit/vrx_kit.dart';

import 'state.dart';

final _events = StreamController<ShellAction>();

/// The screen's settings: the drawer's slider writes the brightness (the
/// display grant); the compositor applies it.
final _screen = ScreenSettings();

void _brightness(int value, {required bool settled}) =>
    unawaited(_screen.setBrightness(value, settled: settled).catchError((Object err) => debugPrint('shell: brightness: $err')));

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

  void _power(Future<void> Function() act) {
    _events.add(ShellAction.powerDismissed);
    unawaited(act().catchError((Object _) {}));
  }

  @override
  Widget build(BuildContext context, ShellView view) {
    final facts = VrxStatusFacts(
      showBack: view.canGoBack || view.askingPower || view.drawer,
      // the one Back: it closes what the shell has open (the power menu,
      // the drawer); otherwise the focused app goes back a screen, or
      // leaves
      onBack: () {
        if (view.askingPower) {
          _events.add(ShellAction.powerDismissed);
        } else if (view.drawer) {
          _toggle();
        } else {
          unawaited(VrxShell.back());
        }
      },
      clockText: view.facts.clockText,
      dateText: view.facts.dateText,
      wifiUp: view.wifiUp,
    );
    // the compositor routes input by the strip's height, and gives the
    // shell all of it while the drawer is open. The drawer is a slide
    // down from the strip and a slide up (or a tap outside it) away; a
    // tap on the strip is only ever its Back (the owner: a tap meant for
    // Back opened the drawer)
    final strip = VrxShellRegion(
      full: view.drawer || view.askingPower,
      child: VrxSwipe(
        onDown: view.drawer || view.askingPower ? null : _toggle,
        onUp: view.drawer ? _toggle : null,
        child: VrxStatusStrip(facts: facts),
      ),
    );
    // the drawer is an overlay of its own (a scrim and a panel) over the
    // strip and the screen below it. Below the strip the shell is clear:
    // its plane sits above the focused app, which shows through.
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(children: [
          strip,
          // the drawer opens under the strip: its scrim and panel fill
          // the rest of the screen
          if (view.drawer)
            Expanded(
              child: VrxSwipe(
                onUp: _toggle,
                child: Stack(children: [
                  VrxQuickDrawer(
                    version: view.version,
                    brightness: view.brightness,
                    onBrightness: (v) => _brightness(v, settled: false),
                    onBrightnessEnd: (v) => _brightness(v, settled: true),
                    wifiUp: view.wifiUp,
                    bleUp: false,
                    onWifi: () {
                      _toggle();
                      Nav.push('wifi');
                    },
                    onPower: () => _events.add(ShellAction.powerAsked),
                    onDismiss: _toggle,
                  ),
                ]),
              ),
            ),
          // the power menu, a screen in the client area below the strip
          // (a menu is a screen, not a dialog: two acts and Cancel do
          // not fit a dialog on the 58mm panel); its Back cancels
          if (view.askingPower)
            Expanded(
              child: ColoredBox(
                color: VrxTheme.of(context).page,
                child: VrxList(children: [
                  // no arrow of its own: the strip's Back closes it
                  const VrxHeader(title: 'Power'),
                  VrxRow(glyph: VrxSymbols.restart_alt, label: 'Restart', onTap: () => _power(VrxSystem.power.reboot)),
                  VrxRow(
                      glyph: VrxSymbols.power_settings_new,
                      label: 'Power off',
                      onTap: () => _power(VrxSystem.power.powerOff)),
                ]),
              ),
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
  _screen.watch().listen((s) => fact(() => model.brightness = s.brightness), onError: (Object _) {});
  unawaited(_screen.dimming().then((d) => fact(() => model.dimming = d)));
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
