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

  void _open() => _events.add(ShellAction.drawerOpened);
  void _close() => _events.add(ShellAction.drawerClosed);

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
          _close();
        } else {
          unawaited(VrxShell.back());
        }
      },
      clockText: view.facts.clockText,
      dateText: view.facts.dateText,
      wifiUp: view.wifiUp,
      bleUp: view.bleUp,
    );
    // the compositor routes input by the strip's height, and gives the shell
    // all of it while the drawer is open, and while a finger or the motion has
    // any of it on screen (plan 0017 D7: VrxPull's `engaged`). The drawer is
    // pulled down from the strip with the finger following it 1:1 and let go
    // onto a spring; a tap on the strip is only ever its Back (the owner: a tap
    // meant for Back opened the drawer)
    // an applet over its power budget (plan 0012 D11): a band under the
    // strip, inside the shell's region (so its input is the shell's and
    // the app below moves down), until the person answers
    final alert = view.drawer || view.askingPower ? null : view.alert;
    // the battery's zone (plan 0012 D10): a sentence under the strip
    // until it charges; critical takes the place of a power alert
    final battery = view.drawer || view.askingPower ? null : view.batteryNotice;
    // the drawer's layer (a scrim and a panel) sits over the screen below the
    // strip; there the shell is clear, its plane above the focused app, which
    // shows through
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: VrxPull(
          open: view.drawer,
          // let go open or shut, or the scrim tapped
          onIntent: (open) => open ? _open() : _close(),
          top: VrxStatusStrip.heightOf(context),
          strip: (context, pull) => VrxShellRegion(
            full: view.drawer || view.askingPower || pull.engaged,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              pull.handle(VrxStatusStrip(facts: facts)),
              if (battery != null)
                VrxBanner(text: battery, signal: view.batteryCritical ? VrxSignal.error : VrxSignal.warning)
              else if (alert != null)
                PowerAlertBand(alert: alert, onAnswer: _answer),
            ]),
          ),
          panel: VrxQuickDrawer(
            version: view.version,
            brightness: view.brightness,
            onBrightness: (v) => _brightness(v, settled: false),
            onBrightnessEnd: (v) => _brightness(v, settled: true),
            wifiUp: view.wifiUp,
            bleUp: view.bleUp,
            onWifi: () {
              _close();
              unawaited(Nav.push('wifi'));
            },
            // Device Link: the radio, pairing and paired phones
            onBle: () {
              _close();
              unawaited(Nav.push('devicelink'));
            },
            onPower: () => _events.add(ShellAction.powerAsked),
          ),
          // the power menu, a screen in the client area below the strip
          // (a menu is a screen, not a dialog: two acts and Cancel do
          // not fit a dialog on the 58mm panel); its Back cancels
          below: view.askingPower
              ? ColoredBox(
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
                )
              : null,
        ),
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
  void fact(ShellFacts f) => _events.add(f);

  VrxSystem.time
      .watch()
      .listen((t) => fact(ShellFacts(clockValid: t.synced || DateTime.now().year >= 2025)), onError: (Object _) {});
  VrxSystem.network.watch().listen((n) => fact(ShellFacts(wifiUp: n.connected != null)), onError: (Object _) {});
  // the radio's switch is connman's (the network grant); the shell does not
  // reach BlueZ, so on or off is all it says
  VrxSystem.bluetooth.watch().listen((b) => fact(ShellFacts(bleUp: b.on)), onError: (Object _) {});
  _screen.watch().listen((s) => fact(ShellFacts(brightness: s.brightness)), onError: (Object _) {});
  // a home app's Level Control (plan 0015 D12): vrxhost tells the shell,
  // which writes it the way its own slider does
  VrxBridge.listen().listen((d) {
    if (d is! VrxIntentDelivery || d.name != 'sys.screen.brightness') return;
    final position = (d.payload is Map ? (d.payload as Map)['position'] : null) as num?;
    final id = d.id;
    if (position != null) _brightness(position.toInt(), settled: true);
    if (id != null) unawaited(VrxBridge.answer(id, handled: position != null).catchError((Object _) {}));
  }, onError: (Object err) => debugPrint('shell: listen: $err'));
  unawaited(_screen.dimming().then((d) => fact(ShellFacts(dimming: d))));
  // the release only ("0.1.0077"): the platform after it is Settings >
  // Device's, and wrapped three lines deep in the drawer
  VrxSystem.device.watch().listen(
      (d) => fact(ShellFacts(version: d.version.isEmpty ? '' : 'vrx ${d.version.split(' ').first}')),
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
    final notice = stopped != null
        ? Change<String?>('${names[stopped] ?? stopped} stopped.')
        : (f.front != front ? const Change<String?>(null) : null);
    front = f.front;
    fact(ShellFacts(depth: f.depth, notice: notice));
  }, onError: (Object _) {});
  VrxSystem.powerSupply.watch().listen((b) => fact(ShellFacts(battery: Change(b))), onError: (Object _) {});
  // the battery's zone and the next wake, vrxhost's (plan 0012 D10, D15)
  AppletsService.installed?.facts().listen(
      (f) => fact(ShellFacts(batteryZone: f.batteryZone, batteryShown: f.battery, nextWake: f.nextWake)),
      onError: (Object _) {});
  unawaited(_screen.cascade().then((c) => fact(ShellFacts(wakeAlarm: c.wakeAlarm))));
  // applets over their power budget (plan 0012 D11), from vrxhost
  if (AppletsService.installed != null) {
    VrxEnergy.service.alerts().listen((a) => fact(ShellFacts(alerts: a)), onError: (Object _) {});
  }
  // the camera's mark (plan 0018 D11): camerad's state file says when any
  // camera runs, whoever started it
  CameraService.instance.active.listen((on) => fact(ShellFacts(cameraOn: on)), onError: (Object _) {});
  // 12 or 24 hours: the system's locale, followed as it changes
  final format = VrxTimeFormat.changes;
  void follow() => fact(ShellFacts(h24: format.value));
  follow();
  format.addListener(follow);
  // the strip's clock changes once a minute: a check every 10 s, a
  // repaint only when the minute turned
  var shown = '';
  // the shell is hidden only with the screen, so this rests while it is off
  VrxTicker(const Duration(seconds: 10), () {
    if (model.clockText != shown) {
      shown = model.clockText;
      _events.add(ShellAction.minute);
    }
  });
}
