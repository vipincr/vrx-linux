/// Software update (plan 0016 D11): the kit's side of vrxhost's
/// `io.vrx.Host.UpdateOffers`, `UpdateInstall`, `UpdateRestart` and
/// `UpdateStatus`. RAUC checks and installs a bundle into the slot that
/// is not running; the restart into it is a trial, kept only if the
/// device comes up healthy. Only a built-in with the `update` grant may
/// ask.
library;

import 'host.dart';

/// A bundle offered: from the USB drive's `updates/` folder or the Manage
/// page's upload.
class UpdateOffer {
  const UpdateOffer({required this.file, required this.version, this.compatible = '', this.problem});

  factory UpdateOffer.fromJson(Map<String, dynamic> j) => UpdateOffer(
        file: j['file'] as String? ?? '',
        version: j['version'] as String? ?? '',
        compatible: j['compatible'] as String? ?? '',
        problem: j['problem'] as String?,
      );

  final String file;
  final String version;

  /// The machine it was built for.
  final String compatible;

  /// Why it cannot be installed (VrxWords.updateProblem says it), or null.
  final String? problem;

  bool get installable => problem == null;
}

/// One root slot as RAUC keeps it.
class UpdateSlot {
  const UpdateSlot({required this.name, required this.bootname, this.state = '', this.bootStatus = '', this.version = ''});

  factory UpdateSlot.fromJson(Map<String, dynamic> j) => UpdateSlot(
        name: j['name'] as String? ?? '',
        bootname: j['bootname'] as String? ?? '',
        state: j['state'] as String? ?? '',
        bootStatus: j['boot_status'] as String? ?? '',
        version: j['version'] as String? ?? '',
      );

  final String name;

  /// What the boot loader calls it ("A", "B").
  final String bootname;

  /// booted, active or inactive.
  final String state;

  /// good or bad.
  final String bootStatus;

  /// The bundle version last installed into it ('' if never).
  final String version;
}

/// The last update's outcome.
enum UpdateOutcome {
  none,

  /// Running the new version on trial: kept once the device is healthy.
  trial,

  /// The new version came up healthy and stays.
  kept,

  /// The new version did not come up healthy; the old one is running.
  fellBack;

  static UpdateOutcome parse(String? s) => switch (s) {
        'trial' => trial,
        'kept' => kept,
        'fell-back' => fellBack,
        _ => none,
      };
}

/// The running version, the slots and the last update's outcome.
class UpdateStatus {
  const UpdateStatus({required this.running, this.booted = '', this.trial = false, this.last = UpdateOutcome.none, this.slots = const []});

  factory UpdateStatus.fromJson(Map<String, dynamic> j) => UpdateStatus(
        running: j['running'] as String? ?? '',
        booted: j['booted'] as String? ?? '',
        trial: j['trial'] as bool? ?? false,
        last: UpdateOutcome.parse(j['last'] as String?),
        slots: [for (final s in (j['slots'] as List? ?? const [])) UpdateSlot.fromJson(s as Map<String, dynamic>)],
      );

  final String running;

  /// The slot booted, by its boot name.
  final String booted;
  final bool trial;
  final UpdateOutcome last;
  final List<UpdateSlot> slots;
}

/// The service.
abstract class UpdateService {
  /// The bundles offered now (the USB drive is read first when nothing
  /// shares it).
  Future<List<UpdateOffer>> offers();

  /// Install [file]; returns its version once it is in the other slot.
  Future<String> install(String file);

  /// Restart into the installed slot on trial.
  Future<void> restart();

  Future<UpdateStatus> status();
}

/// [UpdateService] over vrxhost's `io.vrx.Host`.
class VarlinkUpdateService implements UpdateService {
  VarlinkUpdateService({String socketPath = VarlinkAppletsService.defaultSocket}) : _client = VarlinkClient(socketPath);

  final VarlinkClient _client;

  @override
  Future<List<UpdateOffer>> offers() async {
    final r = await _client.call('io.vrx.Host.UpdateOffers');
    return [for (final o in (r['offers'] as List? ?? const [])) UpdateOffer.fromJson(o as Map<String, dynamic>)];
  }

  @override
  Future<String> install(String file) async =>
      (await _client.call('io.vrx.Host.UpdateInstall', {'file': file}))['version'] as String? ?? '';

  @override
  Future<void> restart() => _client.call('io.vrx.Host.UpdateRestart');

  @override
  Future<UpdateStatus> status() async => UpdateStatus.fromJson(await _client.call('io.vrx.Host.UpdateStatus'));
}

/// The installed update service (vrxhost's; replaced in tests).
abstract final class VrxUpdate {
  static UpdateService? _service;

  static UpdateService get service => _service ??= VarlinkUpdateService();

  /// Replace it (tests, a desktop `flutter run`).
  static void install(UpdateService service) => _service = service;
}
