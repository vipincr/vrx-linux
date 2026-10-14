import 'package:clock_applet/book.dart';
import 'package:clock_applet/state.dart';
import 'package:clock_applet/tz.dart';

/// Every Clock screen, with facts in it, for the layout check and shots.
final now = DateTime.utc(2026, 10, 15, 1, 30).millisecondsSinceEpoch ~/ 1000;

ClockModel model() => ClockModel(now: () => now)
  ..home = Zone.fixed('Asia/Kolkata', 19800)
  ..zones = ['Asia/Kolkata', 'Europe/London', 'America/Argentina/Buenos_Aires', 'Pacific/Auckland']
  ..book.alarms.addAll([const Alarm(minutes: 7 * 60 + 30, days: daysWeek), const Alarm(minutes: 9 * 60 + 30, enabled: false)])
  ..book.world.addAll(['Europe/London', 'America/New_York'])
  ..world['Europe/London'] = Zone.fixed('Europe/London', 3600)
  ..world['America/New_York'] = Zone.fixed('America/New_York', -14400);

/// Apply [action] as the store would: a fixture reaches its screen
/// through the reducer, the only writer (plan 0013 D1).
extension ClockDoes on ClockModel {
  void does(ClockAction action) => reduce(const ClockState(), action);
}

ClockModel ringing() {
  final m = model()
    ..book.checked = now - 60
    ..book.alarms[0] = const Alarm(minutes: 7 * 60, days: daysAll);
  m.does(ClockDo.check);
  return m;
}

final clockScreens = <String, ClockModel Function()>{
  'face': model,
  'face 12h': () => model()..h12 = true,
  'alarms 12h': () => model()..h12 = true..does(const ClockOpenTab(ClockTab.alarms)),
  'world': () => model()..does(const ClockOpenTab(ClockTab.world)),
  'alarms': () => model()..does(const ClockOpenTab(ClockTab.alarms)),
  'editor': () => model()..does(const ClockOpenTab(ClockTab.alarms))..does(const ClockEditAlarm(0)),
  'time': () => model()..does(const ClockOpenTab(ClockTab.alarms))..does(const ClockEditAlarm(0))..does(ClockDo.editTime),
  'timer': () => model()..does(const ClockOpenTab(ClockTab.timer)),
  'running': () => model()..does(const ClockOpenTab(ClockTab.timer))..does(ClockDo.pressDial),
  'precise': () => model()..does(const ClockOpenTab(ClockTab.timer))..does(const ClockTimerMode(TimerMode.precise)),
  'zones': () => model()..does(const ClockOpenTab(ClockTab.world))..does(ClockDo.addCity),
  'ring': ringing,
};
