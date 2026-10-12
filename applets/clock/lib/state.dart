import 'package:vrx_kit/vrx_kit.dart';

/// Everything the clock reacts to.
enum ClockAction {
  init,
  tick,
  formatChanged,
  alarmFired,
  snoozeTapped,
}

/// What the clock draws.
class ClockView {
  const ClockView({
    required this.time,
    required this.is24h,
    required this.ringing,
  });

  /// The time, formatted per the current setting.
  final String time;

  /// 24-hour clock or 12-hour.
  final bool is24h;

  /// An alarm is ringing: the ring route is the front screen.
  final bool ringing;
}

/// The clock model: state as fields, reduce applies and derives the
/// view. The same model a host test drives.
class ClockModel extends StoreModel<ClockState, ClockAction, ClockView> {
  ClockModel({DateTime? now})
      : _now = now ?? DateTime(2026, 1, 1, 13, 4, 0),
        _is24h = true,
        _ringing = false;

  final DateTime _now;
  bool _is24h;
  bool _ringing;

  @override
  ClockState get initial => ClockState(
        hour: _now.hour,
        minute: _now.minute,
        is24h: _is24h,
        ringing: _ringing,
      );

  @override
  ClockAction get bootAction => ClockAction.init;

  @override
  ClockView reduce(ClockState state, ClockAction action) {
    switch (action) {
      case ClockAction.init:
        break;
      case ClockAction.tick:
        break; // the tick updates via the state the host feeds in
      case ClockAction.formatChanged:
        _is24h = !_is24h;
      case ClockAction.alarmFired:
        _ringing = true;
      case ClockAction.snoozeTapped:
        _ringing = false;
    }
    return ClockView(
      time: _format(_now),
      is24h: _is24h,
      ringing: _ringing,
    );
  }

  String _format(DateTime now) {
    if (_is24h) {
      return '${_two(now.hour)}:${_two(now.minute)}';
    }
    final hour = now.hour % 12 == 0 ? 12 : now.hour % 12;
      return '$hour:${_two(now.minute)} ${now.hour < 12 ? 'AM' : 'PM'}';
  }

  String _two(int n) => n.toString().padLeft(2, '0');

  @override
  ClockState get snapshot => ClockState(
        hour: _now.hour,
        minute: _now.minute,
        is24h: _is24h,
        ringing: _ringing,
      );
}

/// The clock's state snapshot: what suspension preserves.
class ClockState {
  const ClockState({
    required this.hour,
    required this.minute,
    required this.is24h,
    required this.ringing,
  });

  final int hour;
  final int minute;
  final bool is24h;
  final bool ringing;
}
