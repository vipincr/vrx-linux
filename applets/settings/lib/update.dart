import 'dart:async';

import 'package:flutter/material.dart' hide Intent; // vrx's Intent
import 'package:vrx_kit/vrx_kit.dart';

import 'state.dart';

/// Settings > Device > Software update (plan 0016 D11): the version
/// running, what the last update did, and the updates offered from this
/// device's USB drive or the Manage page. An install writes the slot
/// that is not running; the restart into it is a trial, and a device
/// that does not come up healthy goes back by itself (D2, D6).
class SoftwareUpdateScreen extends StatelessWidget {
  const SoftwareUpdateScreen({
    super.key,
    required this.status,
    required this.offers,
    required this.installing,
    required this.installed,
    required this.onInstall,
    required this.onRestart,
    required this.onBack,
  });

  /// Null while they load.
  final UpdateStatus? status;
  final List<UpdateOffer>? offers;

  /// The version being installed now, or null.
  final String? installing;

  /// The version installed and waiting for the restart, or null.
  final String? installed;
  final void Function(UpdateOffer) onInstall;
  final VoidCallback onRestart;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final s = status;
    final o = offers;
    final busy = installing != null || installed != null;
    Widget sentence(String text) => Padding(
          padding: EdgeInsets.symmetric(horizontal: ScaledSpacing.of(context).inset, vertical: ScaledSpacing.of(context).xs),
          child: Text(text, style: TypeRole.subtext(context)),
        );
    return VrxList(children: [
      VrxHeader(title: 'Software update', onBack: onBack),
      if (s != null) ...[
        VrxRow(label: 'Running', value: s.running),
        if (s.last == UpdateOutcome.fellBack) ...[
          const VrxRow(label: 'Went back', valueGlyph: VrxSymbols.warning),
          sentence('The last update did not start properly, so the device went back to the version it had. Nothing was lost.'),
        ],
        if (s.trial) sentence('This version is on trial: it stays once the device has started fully.'),
      ],
      if (installed != null) ...[
        VrxRow(label: 'Installed', value: installed, valueGlyph: VrxSymbols.check),
        VrxRow(label: 'Restart to finish', value: '›', onTap: onRestart),
      ] else if (installing != null)
        VrxRow(label: 'Installing $installing…'),
      if (o == null)
        const VrxRow(label: 'Looking for updates…')
      else if (o.isEmpty)
        sentence('No update is waiting. Copy one into the updates folder of this device\'s USB drive, '
            'or send it from Manage from a browser.')
      else
        for (final offer in o)
          VrxRow(
            label: offer.version.isEmpty ? offer.file : 'Version ${offer.version}',
            detail: offer.problem == null ? null : VrxWords.updateProblem(offer.problem!),
            value: offer.installable && !busy ? 'Install' : '',
            valueGlyph: offer.installable ? null : VrxSymbols.warning,
            onTap: offer.installable && !busy ? () => onInstall(offer) : null,
          ),
    ]);
  }
}

/// Whether this device has software update for this applet: vrxhost
/// answers the status only with the update grant on an image with RAUC.
Future<void> findUpdates(void Function(SettingsFacts) fact) async {
  try {
    final status = await VrxUpdate.service.status();
    fact(SettingsFacts(updatesAvailable: true, updateStatus: status));
  } on Object catch (err) {
    debugPrint('settings: no software update: $err');
  }
}

/// The status and the offers again (the screen opened, an install ended).
Future<void> refreshUpdates(void Function(SettingsFacts) fact) async {
  try {
    final status = await VrxUpdate.service.status();
    final offers = await VrxUpdate.service.offers();
    fact(SettingsFacts(updateStatus: status, updateOffers: offers));
  } on Object catch (err) {
    fact(SettingsFacts(updateOffers: const [], error: VrxWords.of(err, context: 'settings: update')));
  }
}

/// Install [offer]: the screen says so while RAUC writes the other slot.
Future<void> installUpdate(UpdateOffer offer, void Function(SettingsFacts) fact) async {
  fact(SettingsFacts(updateInstalling: Change(offer.version.isEmpty ? offer.file : offer.version)));
  try {
    final version = await VrxUpdate.service.install(offer.file);
    fact(SettingsFacts(updateInstalling: const Change(null), updateInstalled: version.isEmpty ? offer.file : version));
  } on Object catch (err) {
    fact(SettingsFacts(updateInstalling: const Change(null), error: VrxWords.of(err, context: 'settings: update')));
  }
  await refreshUpdates(fact);
}

/// Restart into the installed version, once the person says so.
Future<void> restartIntoUpdate(BuildContext context, String version, String running, void Function(SettingsFacts) fact) async {
  final yes = await vrxConfirm(
    context,
    title: 'Restart to finish?',
    message: 'The device restarts into version $version. If it does not start properly, it goes back to $running by itself.',
    act: 'Restart',
  );
  if (!yes) return;
  try {
    await VrxUpdate.service.restart();
  } on Object catch (err) {
    fact(SettingsFacts(error: VrxWords.of(err, context: 'settings: update')));
  }
}
