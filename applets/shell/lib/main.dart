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

  void _answer(PowerAlert alert, {required bool stop}) => unawaited(
      VrxEnergy.service.answer(alert.applet, stop: stop).catchError((Object err) => debugPrint('shell: power alert: $err')));

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
      bleUp: view.bleUp,
    );
    // the compositor routes input by the strip's height, and gives the
    // shell all of it while the drawer is open. The drawer is a slide
    // down from the strip and a slide up (or a tap outside it) away; a
    // tap on the strip is only ever its Back (the owner: a tap meant for
    // Back opened the drawer)
    // an applet over its power budget (plan 0012 D11): a band under the
    // strip, inside the shell's region (so its input is the shell's and
    // the app below moves down), until the person answers
    final alert = view.drawer || view.askingPower ? null : view.alert;
    // the battery's zone (plan 0012 D10): a sentence under the strip
    // until it charges; critical takes the place of a power alert
    final battery = view.drawer || view.askingPower ? null : view.batteryNotice;
    final strip = VrxShellRegion(
      full: view.drawer || view.askingPower,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        VrxSwipe(
          onDown: view.drawer || view.askingPower ? null : _toggle,
          onUp: view.drawer ? _toggle : null,
          child: VrxStatusStrip(facts: facts),
        ),
        if (battery != null)
          VrxBanner(text: battery, signal: view.batteryCritical ? VrxSignal.error : VrxSignal.warning)
        else if (alert != null)
          PowerAlertBand(alert: alert, onAnswer: _answer),
      ]),
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
                    bleUp: view.bleUp,
                    onWifi: () {
                      _toggle();
                      unawaited(Nav.push('wifi'));
                    },
                    // Device Link: the radio, pairing and paired phones
                    onBle: () {
                      _toggle();
                      unawaited(Nav.push('devicelink'));
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
                  // an alarm that cannot ring through a power-off is said
                  // before it, whole (plan 0012 D15, the evrx-rt lesson)
                  if (view.powerOffNote != null) VrxBanner(text: view.powerOffNote!, signal: VrxSignal.warning),
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

/// The band: what is using power, in a sentence, and the two answers
/// (the act last and filled, as a confirm's; "Not now" leaves the
/// applet alone).
class PowerAlertBand extends StatelessWidget {
  const PowerAlertBand({super.key, required this.alert, required this.onAnswer});

  final PowerAlert alert;
  final void Function(PowerAlert alert, {required bool stop}) onAnswer;

  @override
  Widget build(BuildContext context) {
    final s = ScaledSpacing.of(context);
    return ColoredBox(
      color: VrxTheme.of(context).page,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        VrxBanner(text: alert.sentence, signal: VrxSignal.warning),
        Padding(
          padding: EdgeInsets.fromLTRB(s.inset, s.xs, s.inset, s.sm),
          child: Row(children: [
            Expanded(child: VrxChip(label: 'Not now', fit: true, onTap: () => onAnswer(alert, stop: false))),
            SizedBox(width: s.sm),
            Expanded(child: VrxChip(label: 'Stop', fit: true, filled: true, onTap: () => onAnswer(alert, stop: true))),
          ]),
        ),
      ]),
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
  // the radio's switch is connman's (the network grant); the shell does not
  // reach BlueZ, so on or off is all it says
  VrxSystem.bluetooth.watch().listen((b) => fact(() => model.bleUp = b.on), onError: (Object _) {});
  _screen.watch().listen((s) => fact(() => model.brightness = s.brightness), onError: (Object _) {});
  unawaited(_screen.dimming().then((d) => fact(() => model.dimming = d)));
  // the release only ("0.1.0077"): the platform after it is Settings >
  // Device's, and wrapped three lines deep in the drawer
  VrxSystem.device.watch().listen(
      (d) => fact(() => model.version = d.version.isEmpty ? '' : 'vrx ${d.version.split(' ').first}'),
      onError: (Object _) {});
  // the trail's depth, and an applet that stopped: said once, by its
  // name, until the next navigation (plan 0011 D2)
  final names = <String, String>{};
  var front = '';
  AppletsService.installed?.watch().listen((f) async {
    final stopped = f.stopped;
    if (stopped != null && names.isEmpty) {
      try {
        for (final a in await AppletsService.installed!.applets()) {
          names[a.id] = a.name;
        }
      } on Object catch (_) {
        // the id is said instead
      }
    }
    fact(() {
      model.depth = f.depth;
      if (stopped != null) {
        model.notice = '${names[stopped] ?? stopped} stopped.';
      } else if (f.front != front) {
        model.notice = null;
      }
      front = f.front;
    });
  }, onError: (Object _) {});
  VrxSystem.powerSupply.watch().listen((b) => fact(() => model.battery = b), onError: (Object _) {});
  // the battery's zone and the next wake, vrxhost's (plan 0012 D10, D15)
  AppletsService.installed?.facts().listen(
      (f) => fact(() {
            model.batteryZone = f.batteryZone;
            model.batteryShown = f.battery;
            model.nextWake = f.nextWake;
          }),
      onError: (Object _) {});
  unawaited(_screen.cascade().then((c) => fact(() => model.wakeAlarm = c.wakeAlarm)));
  // applets over their power budget (plan 0012 D11), from vrxhost
  if (AppletsService.installed != null) {
    VrxEnergy.service.alerts().listen((a) => fact(() => model.alerts = a), onError: (Object _) {});
  }
  // 12 or 24 hours: the system's locale, followed as it changes
  final format = VrxTimeFormat.changes;
  void follow() => fact(() => model.h24 = format.value);
  follow();
  format.addListener(follow);
  // the strip's clock changes once a minute: a check every 10 s, a
  // repaint only when the minute turned
  var shown = '';
  // the shell is hidden only with the screen, so this rests while it is off
  VrxTicker(const Duration(seconds: 10), () {
    if (model.clockText != shown) {
      shown = model.clockText;
      _events.add(ShellAction.factsChanged);
    }
  });
}
