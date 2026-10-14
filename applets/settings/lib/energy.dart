import 'package:flutter/material.dart' hide Intent; // vrx's Intent
import 'package:vrx_kit/vrx_kit.dart';

/// Settings > Power > Battery use (plan 0012 D12): applets and the
/// system's parts by what they used over the last day, from vrxhost's
/// estimate. A board whose power was never measured says so, and ranks
/// by the time each kept the processor busy instead of inventing energy.
class BatteryUseScreen extends StatelessWidget {
  const BatteryUseScreen({super.key, required this.report, required this.onBack});

  /// Null while it loads.
  final EnergyReport? report;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final r = report;
    return VrxList(children: [
      VrxHeader(title: 'Battery use', onBack: onBack),
      if (r == null)
        const VrxRow(label: 'Reading what each applet used…')
      else ...[
        if (r.calibrated)
          VrxRow(
            label: 'Last ${r.hours} hours',
            detail: r.measured == null ? null : 'Measured ${r.measured}',
            value: energyLabel(r.totalMillijoules ?? 0),
          )
        else ...[
          const VrxRow(label: 'Not calibrated'),
          // a sentence, not a row's detail: it wraps as far as it needs
          Padding(
            padding: EdgeInsets.symmetric(horizontal: ScaledSpacing.of(context).inset, vertical: ScaledSpacing.of(context).xs),
            child: Text(
              r.problem ??
                  'This board\'s power has not been measured. Applets are ranked by the time they kept the processor busy.',
              style: TypeRole.subtext(context),
            ),
          ),
        ],
        if (r.rows.isEmpty) const VrxRow(label: 'Nothing has used power yet.'),
        for (final row in r.rows)
          VrxRow(
            label: row.name,
            detail: row.over
                ? 'Over its budget'
                : row.system
                    ? 'System'
                    : row.frontSeconds > 0
                        ? 'In front ${busyLabel(row.frontSeconds * 1000)}'
                        : 'Behind the screen',
            value: r.calibrated ? energyLabel(row.millijoules ?? 0) : busyLabel(row.busyMs),
            // a signal is never colour alone: the glyph and the words
            valueGlyph: row.over ? VrxSymbols.warning : null,
          ),
      ],
    ]);
  }
}

/// Settings > Power > Why it is awake (plan 0012 D12): what holds the
/// device awake right now, from Linux (logind's inhibitors, the wakeup
/// sources, cpufreq, the thermal zone) through vrxhost.
class WhyAwakeScreen extends StatelessWidget {
  const WhyAwakeScreen({super.key, required this.awake, required this.names, required this.onBack});

  /// Null while it loads.
  final AwakeReport? awake;

  /// Applet ids to the names a person knows.
  final Map<String, String> names;
  final VoidCallback onBack;

  String _name(String id) => names[id] ?? id;

  @override
  Widget build(BuildContext context) {
    final a = awake;
    return VrxList(children: [
      VrxHeader(title: 'Why it is awake', onBack: onBack),
      if (a == null)
        const VrxRow(label: 'Asking the system…')
      else ...[
        VrxRow(label: 'Screen', value: a.screenOn ? 'On' : 'Off'),
        VrxRow(label: 'Processor', value: a.khz > 0 ? '${a.khz ~/ 1000} MHz' : '', detail: a.governor.isEmpty ? null : 'Speed follows ${a.governor}'),
        if (a.tempMilliC != null) VrxRow(label: 'Temperature', value: '${(a.tempMilliC! / 1000).round()} °C'),
        if (a.supplyLow) const VrxRow(label: 'Supply', value: 'Too low', valueGlyph: VrxSymbols.warning),
        if (a.inhibitors.isEmpty)
          const VrxRow(label: 'Nothing is holding it awake')
        else
          for (final i in a.inhibitors)
            VrxRow(
              label: i.applet != null ? _name(i.applet!) : i.who,
              detail: i.why.isEmpty ? null : i.why,
              value: i.what.contains('sleep') ? 'Keeps it from sleeping' : 'Keeps the screen on',
            ),
        VrxRow(
          label: 'Running',
          value: '${a.running.length}',
          detail: a.running.isEmpty ? null : a.running.map(_name).join(', '),
        ),
        VrxRow(
          label: 'Resting behind the screen',
          value: '${a.frozen.length}',
          detail: a.frozen.isEmpty ? null : a.frozen.map(_name).join(', '),
        ),
        for (final (name, events) in a.wakeups.take(5))
          VrxRow(label: name, detail: 'Wakes the device', value: '$events'),
      ],
    ]);
  }
}
