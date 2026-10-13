/// A battery, where the kernel reports one (plan 0011 D12), Linux first:
/// the `power_supply` class in sysfs is the one home of the facts
/// (`type`, `capacity`, `voltage_now`, `status`); nothing keeps a second
/// copy of them (UPower is not used for that reason). The class's change
/// uevents reach applets as vrxhost's `sys.power.changed`, and a reading
/// follows them. No current machine has a battery: then there is none,
/// and nothing about a battery is shown.
library;

import 'dart:async';
import 'dart:io';

import 'channel.dart';

/// One battery's state.
class Battery {
  const Battery({required this.name, required this.percent, required this.charging, this.volts, this.full = false});

  /// The supply's name in sysfs (`BAT0`).
  final String name;

  /// 0-100; null when the gauge does not say.
  final int? percent;
  final bool charging;
  final bool full;

  /// The voltage now, in volts, when the gauge reports it.
  final double? volts;
}

class PowerSupplyService {
  PowerSupplyService({this.root = '/sys/class/power_supply'});

  final String root;

  /// The first battery, or null when there is none.
  Future<Battery?> battery() async {
    final dir = Directory(root);
    if (!await dir.exists()) return null;
    final names = [await for (final e in dir.list()) e.uri.pathSegments.where((s) => s.isNotEmpty).last]..sort();
    for (final name in names) {
      Future<String?> read(String attr) async {
        try {
          return (await File('$root/$name/$attr').readAsString()).trim();
        } on FileSystemException {
          return null;
        }
      }

      if (await read('type') != 'Battery') continue;
      if (await read('present') == '0') continue;
      final status = await read('status') ?? '';
      final micro = int.tryParse(await read('voltage_now') ?? '');
      return Battery(
        name: name,
        percent: int.tryParse(await read('capacity') ?? '')?.clamp(0, 100),
        charging: status == 'Charging',
        full: status == 'Full',
        volts: micro == null ? null : micro / 1e6,
      );
    }
    return null;
  }

  /// The battery now and again on every `sys.power.changed` (the applet
  /// declares that it handles it).
  Stream<Battery?> watch() async* {
    yield await battery();
    await for (final d in VrxBridge.listen()) {
      if (d is VrxIntentDelivery && d.name == 'sys.power.changed') yield await battery();
    }
  }
}
