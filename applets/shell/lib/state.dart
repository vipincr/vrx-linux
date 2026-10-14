import 'package:vrx_kit/vrx_kit.dart';

/// Everything the shell reacts to (plan 0013 D1: the reducer is the only
/// writer): a signal, or the system's facts carried as data.
sealed class ShellAction {
  const ShellAction();

  static const init = ShellSignal.init;
  static const drawerOpened = ShellSignal.drawerOpened;
  static const drawerClosed = ShellSignal.drawerClosed;
  static const powerAsked = ShellSignal.powerAsked;
  static const powerDismissed = ShellSignal.powerDismissed;
  static const back = ShellSignal.back;
  static const minute = ShellSignal.minute;
}

/// [minute]: the clock's minute turned; the strip is drawn again.
enum ShellSignal implements ShellAction { init, drawerOpened, drawerClosed, powerAsked, powerDismissed, back, minute }

/// What the strip and the drawer show (null fields: unchanged; Change
/// for what may become null).
final class ShellFacts implements ShellAction {
  const ShellFacts({
    this.clockValid,
    this.wifiUp,
    this.wiredUp,
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
    this.cameraOn,
  });

  final bool? clockValid;
  final bool? wifiUp;

  /// A cable is in and the wired link has an address (connman).
  final bool? wiredUp;
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

  /// camerad says a camera is running (plan 0018 D11).
  final bool? cameraOn;
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
  bool wiredUp = false;
  bool bleUp = false;

  /// A camera is running now, whoever started it: the strip's mark
  /// (plan 0018 D11).
  bool cameraOn = false;

  /// How the compositor dims, and the brightness setting (plan 0010 D8).
  VrxDimming dimming = VrxDimming.none;
  int brightness = ScreenSettings.defaultBrightness;
  bool clockValid = false;
  String version = '';

  /// The back trail's depth (vrxhost), Home included: Back is offered
  /// above Home (the bench showed it on Home at depth > 0).
  int trailDepth = 0;

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
      // the drawer was let go open or shut (VrxPull holds its position; the
      // model holds the intent, and saying it twice is saying it once)
      case ShellAction.drawerOpened:
        drawer = true;
      case ShellAction.drawerClosed:
        drawer = false;
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
        wiredUp = f.wiredUp ?? wiredUp;
        bleUp = f.bleUp ?? bleUp;
        brightness = f.brightness ?? brightness;
        dimming = f.dimming ?? dimming;
        version = f.version ?? version;
        trailDepth = f.depth ?? trailDepth;
        if (f.notice != null) notice = f.notice!.value;
        if (f.battery != null) battery = f.battery!.value;
        batteryZone = f.batteryZone ?? batteryZone;
        batteryShown = f.batteryShown ?? batteryShown;
        nextWake = f.nextWake ?? nextWake;
        wakeAlarm = f.wakeAlarm ?? wakeAlarm;
        alerts = f.alerts ?? alerts;
        h24 = f.h24 ?? h24;
        cameraOn = f.cameraOn ?? cameraOn;
      case ShellAction.init || ShellAction.minute:
        break;
    }
    return ShellView(
      drawer: drawer,
      askingPower: askingPower,
      facts: VrxStatusFacts(
        showBack: trailDepth > 1,
        clockText: clockText,
        dateText: dateText,
        wifiUp: wifiUp,
        wiredUp: wiredUp,
        bleUp: bleUp,
        notice: notice,
        batteryLevel: battery?.percent,
        batteryCharging: battery?.charging ?? false,
        cameraOn: cameraOn,
      ),
      version: version,
      brightness: dimming == VrxDimming.none ? null : brightness,
      wifiUp: wifiUp,
      bleUp: bleUp,
      canGoBack: trailDepth > 1,
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

  // one screen: the drawer and the power menu move on their own (VrxPull),
  // and the kit's screen slide is not for them
  @override
  Object get screen => 0;

  @override
  int get depth => 0;

  @override
  Object? get fingerprint => [drawer, askingPower, wifiUp, wiredUp, bleUp, dimming, brightness, clockValid, version, trailDepth,
      battery?.percent, notice, h24, [for (final a in alerts) '${a.applet}/${a.answer}'], batteryZone, batteryShown,
      nextWake, wakeAlarm, cameraOn];
}

class ShellState {
  const ShellState();
}
