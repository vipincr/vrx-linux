/// What each applet costs, why the device is awake, and the applets over
/// their power budget (plan 0012 D8, D11, D12): the kit's side of
/// vrxhost's `io.vrx.Host.Energy`, `Awake`, `PowerAlerts` and
/// `PowerAlertAnswer`. vrxhost samples Linux's counters and prices them
/// with the board's measured profile; a board whose profile has no
/// measured numbers says "not calibrated" and ranks by time instead.
library;

import 'dart:async';

import 'host.dart';

/// One row of the ranking: an applet, or a part of the system (the
/// screen, Wi-Fi, Bluetooth, the idle floor, the local models, the rest).
class EnergyRow {
  const EnergyRow({
    required this.key,
    required this.name,
    required this.system,
    required this.millijoules,
    required this.cpuMs,
    required this.gpuMs,
    required this.wakeups,
    required this.frontSeconds,
    required this.over,
  });

  factory EnergyRow.fromJson(Map<String, dynamic> j) => EnergyRow(
        key: j['key'] as String? ?? '',
        name: j['name'] as String? ?? '',
        system: j['kind'] == 'system',
        millijoules: (j['mj'] as num?)?.toInt(),
        cpuMs: (j['cpu_ms'] as num?)?.toInt() ?? 0,
        gpuMs: (j['gpu_ms'] as num?)?.toInt() ?? 0,
        wakeups: (j['wakeups'] as num?)?.toInt() ?? 0,
        frontSeconds: (j['front_s'] as num?)?.toInt() ?? 0,
        over: j['over'] as bool? ?? false,
      );

  /// An applet id, or `system:screen` and its siblings.
  final String key;
  final String name;
  final bool system;

  /// Millijoules over the period; null on a board that is not calibrated.
  final int? millijoules;
  final int cpuMs;
  final int gpuMs;
  final int wakeups;
  final int frontSeconds;

  /// Over its budget now.
  final bool over;

  /// CPU and GPU time together, what an uncalibrated board ranks by.
  int get busyMs => cpuMs + gpuMs;
}

/// The ranking over the last [hours].
class EnergyReport {
  const EnergyReport({required this.calibrated, required this.hours, required this.rows, this.measured, this.problem});

  factory EnergyReport.fromJson(Map<String, dynamic> j) => EnergyReport(
        calibrated: j['calibrated'] as bool? ?? false,
        measured: j['measured'] as String?,
        problem: j['problem'] as String?,
        hours: (j['hours'] as num?)?.toInt() ?? 24,
        rows: [for (final r in (j['rows'] as List? ?? const [])) EnergyRow.fromJson(r as Map<String, dynamic>)],
      );

  final bool calibrated;

  /// "2026-10-14 with fnb58": when and with what the board was measured.
  final String? measured;

  /// Why the board's profile was refused, if it was.
  final String? problem;
  final int hours;

  /// Most first.
  final List<EnergyRow> rows;

  /// The whole period's energy, null when not calibrated.
  int? get totalMillijoules => calibrated ? rows.fold<int>(0, (t, r) => t + (r.millijoules ?? 0)) : null;
}

/// A logind inhibitor, and the applet holding it if one does.
class AwakeInhibitor {
  const AwakeInhibitor({required this.what, required this.who, required this.why, required this.mode, this.applet});

  final String what;
  final String who;
  final String why;
  final String mode;
  final String? applet;
}

/// Why the device is awake (plan 0012 D12).
class AwakeReport {
  const AwakeReport({
    this.inhibitors = const [],
    this.running = const [],
    this.frozen = const [],
    this.wakeups = const [],
    this.governor = '',
    this.khz = 0,
    this.tempMilliC,
    this.supplyLow = false,
    this.screenOn = false,
  });

  factory AwakeReport.fromJson(Map<String, dynamic> j) => AwakeReport(
        inhibitors: [
          for (final i in (j['inhibitors'] as List? ?? const []))
            AwakeInhibitor(
              what: (i as Map<String, dynamic>)['what'] as String? ?? '',
              who: i['who'] as String? ?? '',
              why: i['why'] as String? ?? '',
              mode: i['mode'] as String? ?? '',
              applet: i['applet'] as String?,
            ),
        ],
        running: [for (final r in (j['running'] as List? ?? const [])) r as String],
        frozen: [for (final r in (j['frozen'] as List? ?? const [])) r as String],
        wakeups: [
          for (final w in (j['wakeups'] as List? ?? const []))
            ((w as Map<String, dynamic>)['name'] as String? ?? '', (w['events'] as num?)?.toInt() ?? 0),
        ],
        governor: j['governor'] as String? ?? '',
        khz: (j['khz'] as num?)?.toInt() ?? 0,
        tempMilliC: (j['temp_mc'] as num?)?.toInt(),
        supplyLow: j['supply_low'] as bool? ?? false,
        screenOn: j['screen_on'] as bool? ?? false,
      );

  final List<AwakeInhibitor> inhibitors;
  final List<String> running;
  final List<String> frozen;

  /// Wakeup sources by event count: (name, events).
  final List<(String, int)> wakeups;
  final String governor;
  final int khz;
  final int? tempMilliC;
  final bool supplyLow;
  final bool screenOn;
}

/// An applet over its power budget: the shell's banner.
class PowerAlert {
  const PowerAlert({required this.applet, required this.name, required this.background, required this.percent, this.answer = ''});

  factory PowerAlert.fromJson(Map<String, dynamic> j) => PowerAlert(
        applet: j['applet'] as String? ?? '',
        name: j['name'] as String? ?? '',
        background: j['budget'] != 'front',
        percent: (j['percent'] as num?)?.toDouble() ?? 0,
        answer: j['answer'] as String? ?? '',
      );

  final String applet;
  final String name;

  /// Over its budget behind the screen (else in front).
  final bool background;
  final double percent;

  /// '' until answered; later, stop, frozen or kept.
  final String answer;

  /// Waiting for the person.
  bool get open => answer.isEmpty;

  /// The banner's sentence (plan 0012 D11).
  String get sentence =>
      background ? '$name is using a lot of power in the background.' : '$name is using a lot of power.';
}

/// The service.
abstract class EnergyService {
  /// The ranking over the last [hours] (1-24).
  Future<EnergyReport> energy({int hours = 24});

  /// Why the device is awake now.
  Future<AwakeReport> awake();

  /// The open power alerts now, and again on every change (the shell).
  Stream<List<PowerAlert>> alerts();

  /// The person's answer: [stop] stops the applet; otherwise nothing is
  /// done to it.
  Future<void> answer(String applet, {required bool stop});
}

/// [EnergyService] over vrxhost's `io.vrx.Host`.
class VarlinkEnergyService implements EnergyService {
  VarlinkEnergyService({String socketPath = VarlinkAppletsService.defaultSocket}) : _client = VarlinkClient(socketPath);

  final VarlinkClient _client;

  @override
  Future<EnergyReport> energy({int hours = 24}) async =>
      EnergyReport.fromJson(await _client.call('io.vrx.Host.Energy', {'hours': hours}));

  @override
  Future<AwakeReport> awake() async => AwakeReport.fromJson(await _client.call('io.vrx.Host.Awake'));

  @override
  Stream<List<PowerAlert>> alerts() => resubscribed(() => _client.stream('io.vrx.Host.PowerAlerts').map(
        (p) => [for (final a in (p['alerts'] as List? ?? const [])) PowerAlert.fromJson(a as Map<String, dynamic>)],
      ));

  @override
  Future<void> answer(String applet, {required bool stop}) =>
      _client.call('io.vrx.Host.PowerAlertAnswer', {'applet': applet, 'answer': stop ? 'stop' : 'later'});
}

/// The installed energy service (vrxhost's; replaced in tests).
abstract final class VrxEnergy {
  static EnergyService? _service;

  static EnergyService get service => _service ??= VarlinkEnergyService();

  /// Replace it (tests, a desktop `flutter run`).
  static void install(EnergyService service) => _service = service;
}

/// "1.2 J", "340 J", "2.4 kJ", "1.5 Wh": an amount a person can compare.
String energyLabel(int millijoules) {
  final j = millijoules / 1000;
  if (j < 10) return '${j.toStringAsFixed(1)} J';
  if (j < 1000) return '${j.round()} J';
  final wh = j / 3600;
  if (wh >= 1) return '${wh.toStringAsFixed(1)} Wh';
  return '${(j / 1000).toStringAsFixed(1)} kJ';
}

/// "12 s", "4 min", "1 h 20 min": busy time for an uncalibrated board.
String busyLabel(int ms) {
  final s = ms ~/ 1000;
  if (s < 60) return '$s s';
  final m = s ~/ 60;
  if (m < 60) return '$m min';
  return '${m ~/ 60} h ${m % 60} min';
}
