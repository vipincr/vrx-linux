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

ClockModel ringing() {
  final m = model()
    ..book.checked = now - 60
    ..book.alarms[0] = const Alarm(minutes: 7 * 60, days: daysAll);
  m.check();
  return m;
}

final clockScreens = <String, ClockModel Function()>{
  'face': model,
  'world': () => model()..openTab(ClockTab.world),
  'alarms': () => model()..openTab(ClockTab.alarms),
  'editor': () => model()..openTab(ClockTab.alarms)..editAlarm(0),
  'time': () => model()..openTab(ClockTab.alarms)..editAlarm(0)..editTime(),
  'timer': () => model()..openTab(ClockTab.timer),
  'running': () => model()..openTab(ClockTab.timer)..pressDial(),
  'precise': () => model()..openTab(ClockTab.timer)..setMode(TimerMode.precise),
  'zones': () => model()..openTab(ClockTab.world)..addCity(),
  'ring': ringing,
};
