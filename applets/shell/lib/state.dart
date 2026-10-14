import 'package:vrx_kit/vrx_kit.dart';

/// Everything the shell reacts to (plan 0013 D1: the reducer is the only
/// writer): a signal, or the system's facts carried as data.
sealed class ShellAction {
  const ShellAction();

  static const init = ShellSignal.init;
  static const drawerToggled = ShellSignal.drawerToggled;
  static const powerAsked = ShellSignal.powerAsked;
  static const powerDismissed = ShellSignal.powerDismissed;
  static const back = ShellSignal.back;
  static const minute = ShellSignal.minute;
}

/// [minute]: the clock's minute turned; the strip is drawn again.
enum ShellSignal implements ShellAction { init, drawerToggled, powerAsked, powerDismissed, back, minute }

/// What the strip and the drawer show (null fields: unchanged; Change
/// for what may become null).
final class ShellFacts implements ShellAction {
  const ShellFacts({
    this.clockValid,
    this.wifiUp,
    this.bleUp,
    this.brightness,
    this.dimming,
    this.version,
    this.depth,
    this.notice,
    this.battery,
    this.batteryZone,
    this.batteryShown,
    this.nextWake,
    this.wakeAlarm,
    this.alerts,
    this.h24,
  });

  final bool? clockValid;
  final bool? wifiUp;
  final bool? bleUp;
  final int? brightness;
  final VrxDimming? dimming;
  final String? version;
  final int? depth;
  final Change<String?>? notice;
  final Change<Battery?>? battery;
  final String? batteryZone;
  final int? batteryShown;
  final int? nextWake;
  final bool? wakeAlarm;
  final List<PowerAlert>? alerts;
  final bool? h24;
}

class ShellView {
  const ShellView({
    required this.drawer,
    this.askingPower = false,
    required this.facts,
    required this.version,
    this.brightness,
    required this.wifiUp,
    this.bleUp = false,
    required this.canGoBack,
    this.alert,
    this.batteryNotice,
    this.batteryCritical = false,
    this.powerOffNote,
  });

  /// The drawer is open (the shell asks for the whole screen).
  final bool drawer;

  /// The power question is up (restart, power off); the shell keeps the
  /// whole screen until it is answered.
  final bool askingPower;
  final VrxStatusFacts facts;
  final String version;

  /// The brightness slider's position; null where the screen does not dim.
  final int? brightness;
  final bool wifiUp;

  /// The Bluetooth radio is on (connman).
  final bool bleUp;
  final bool canGoBack;

  /// An applet over its power budget, waiting for the person (plan 0012
  /// D11): a band under the strip with Not now and Stop.
  final PowerAlert? alert;

  /// The battery's zone in words (plan 0012 D10), under the strip until
  /// it charges; critical says the device is about to turn off.
  final String? batteryNotice;
  final bool batteryCritical;

  /// Said beside Power off when an alarm is set and nothing can wake the
  /// board for it (no RTC): it will not ring while the device is off.
  final String? powerOffNote;
}

/// The shell's model: facts from the services, the drawer's state.
class ShellModel extends StoreModel<ShellState, ShellAction, ShellView> {
  ShellModel({int Function()? now}) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final int Function() _now;
  bool drawer = false;
  bool askingPower = false;
  bool wifiUp = false;
  bool bleUp = false;

  /// How the compositor dims, and the brightness setting (plan 0010 D8).
  VrxDimming dimming = VrxDimming.none;
  int brightness = ScreenSettings.defaultBrightness;
  bool clockValid = false;
  String version = '';

  /// The back trail's depth (vrxhost), Home included: Back is offered
  /// above Home (the bench showed it on Home at depth > 0).
  int depth = 0;

  /// The battery, where the kernel reports one (plan 0011 D12).
  Battery? battery;

  /// "Recorder stopped.": said once in the strip, until the next
  /// navigation (plan 0011 D2).
  String? notice;

  /// 12 or 24 hours: the system's locale (plan 0011 D7).
  bool h24 = true;

  /// The power alerts vrxhost raised (plan 0012 D11); the first open one
  /// is shown.
  List<PowerAlert> alerts = const [];

  /// vrxhost's battery zone ('', 'warn', 'critical') and charge as shown
  /// (plan 0012 D10), and the next time an applet asked to wake for (0:
  /// none) with whether an RTC can wake the board for it (plan 0012 D15).
  String batteryZone = '';
  int batteryShown = -1;
  int nextWake = 0;
  bool wakeAlarm = false;

  String? get batteryNotice => switch (batteryZone) {
        'warn' => 'The battery is low (${batteryShown < 0 ? '' : '$batteryShown %'}). The screen is dimmer until it charges.'
            .replaceFirst(' ()', ''),
        'critical' => 'The battery is almost empty. The device turns off in 30 seconds unless it charges.',
        _ => null,
      };

  String? get powerOffNote {
    if (nextWake <= 0 || wakeAlarm) return null;
    final t = DateTime.fromMillisecondsSinceEpoch(nextWake * 1000);
    return 'An alarm is set for ${VrxTimeFormat.hm(t.hour * 60 + t.minute, h24: h24)}. '
        'It will not ring while the device is off.';
  }

  String get clockText {
    if (!clockValid) return '--:--';
    final t = DateTime.fromMillisecondsSinceEpoch(_now());
    return VrxTimeFormat.hm(t.hour * 60 + t.minute, h24: h24);
  }

  static const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  /// "Tue 13 Oct"; nothing while the clock is unset.
  String? get dateText {
    if (!clockValid) return null;
    final t = DateTime.fromMillisecondsSinceEpoch(_now());
    return '${_days[t.weekday - 1]} ${t.day} ${_months[t.month - 1]}';
  }

  @override
  ShellState get initial => const ShellState();

  @override
  ShellAction get bootAction => ShellAction.init;

  @override
  ShellView reduce(ShellState state, ShellAction action) {
    switch (action) {
      case ShellAction.drawerToggled:
        drawer = !drawer;
      case ShellAction.powerAsked:
        // the drawer closes before acting; the question takes its place
        drawer = false;
        askingPower = true;
      case ShellAction.powerDismissed:
        askingPower = false;
      case ShellSignal.back:
        if (askingPower) {
          askingPower = false;
        } else {
          drawer = false;
        }
      case ShellFacts f:
        clockValid = f.clockValid ?? clockValid;
        wifiUp = f.wifiUp ?? wifiUp;
        bleUp = f.bleUp ?? bleUp;
        brightness = f.brightness ?? brightness;
        dimming = f.dimming ?? dimming;
        version = f.version ?? version;
        depth = f.depth ?? depth;
        if (f.notice != null) notice = f.notice!.value;
        if (f.battery != null) battery = f.battery!.value;
        batteryZone = f.batteryZone ?? batteryZone;
        batteryShown = f.batteryShown ?? batteryShown;
        nextWake = f.nextWake ?? nextWake;
        wakeAlarm = f.wakeAlarm ?? wakeAlarm;
        alerts = f.alerts ?? alerts;
        h24 = f.h24 ?? h24;
      case ShellAction.init || ShellAction.minute:
        break;
    }
    return ShellView(
      drawer: drawer,
      askingPower: askingPower,
      facts: VrxStatusFacts(
        showBack: depth > 1,
        clockText: clockText,
        dateText: dateText,
        wifiUp: wifiUp,
        bleUp: bleUp,
        notice: notice,
        batteryLevel: battery?.percent,
        batteryCharging: battery?.charging ?? false,
      ),
      version: version,
      brightness: dimming == VrxDimming.none ? null : brightness,
      wifiUp: wifiUp,
      bleUp: bleUp,
      canGoBack: depth > 1,
      alert: alerts.where((a) => a.open).firstOrNull,
      batteryNotice: batteryNotice,
      batteryCritical: batteryZone == 'critical',
      powerOffNote: powerOffNote,
    );
  }

  @override
  ShellState get snapshot => const ShellState();

  /// The facts are the system's, read again at every start.
  @override
  void restore(ShellState snapshot) {}

  @override
  ShellAction get backAction => ShellAction.back;

  @override
  bool get atRoot => !drawer && !askingPower;

  @override
  Object? get fingerprint => [drawer, askingPower, wifiUp, bleUp, dimming, brightness, clockValid, version, depth,
      battery?.percent, notice, h24, [for (final a in alerts) '${a.applet}/${a.answer}'], batteryZone, batteryShown,
      nextWake, wakeAlarm];
}

class ShellState {
  const ShellState();
}
