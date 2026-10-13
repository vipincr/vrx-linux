/// The modal family, ported from evrx-rt: a modal before an
/// irreversible act. The contracts:
///
/// - Cancel sits LEFT — the safe answer is read first and is first
/// - the destructive act is LAST and FILLED (inversion carries the
///   weight)
/// - name the act, never "OK" — and say what will go ("The 07:00
///   alarm will be deleted."), not "Are you sure?"
/// - a modal owns the screen until answered; nothing behind it
///   answers while it is open
/// - Back (the strip's, Escape, the mouse's back button) answers Cancel
///   and closes the modal, never the screen under it (plan 0011 D1)
///
/// [vrxConfirm] and [vrxAsk] are the only way an applet opens one: a
/// Flutter `DialogRoute` whose Back is Cancel.
library;

import 'package:flutter/material.dart';

import 'components.dart';
import 'input.dart';
import 'metrics.dart';
import 'scale.dart';
import 'theme.dart';

/// Ask [title] with one act, [act], beside Cancel. True when the act
/// was chosen; false on Cancel, Back, or a tap outside.
Future<bool> vrxConfirm(
  BuildContext context, {
  required String title,
  required String message,
  required String act,
  String cancelLabel = 'Cancel',
}) async =>
    await vrxAsk(context, title: title, message: message, acts: [act], cancelLabel: cancelLabel) == 0;

/// Ask [title] with up to two [acts] under Cancel (the last is filled).
/// The index of the act chosen, or null on Cancel, Back, or a tap
/// outside.
Future<int?> vrxAsk(
  BuildContext context, {
  required String title,
  required String message,
  required List<String> acts,
  String cancelLabel = 'Cancel',
}) {
  assert(acts.length <= 2, 'three acts is a menu, and a menu is a screen');
  // the dialog's own route, not the trail: a modal is the kit's to open
  // and close, so an applet never touches a Navigator
  final navigator = Navigator.of(context); // vrx-allow: the modal's own route
  return navigator.push<int>(DialogRoute<int>(
    context: context,
    // the page dimmed, as the drawer's scrim; a tap on it is Cancel
    barrierColor: VrxTheme.of(context).page.withValues(alpha: 0.6),
    builder: (dialog) {
      void answer(int? index) => Navigator.of(dialog).pop(index); // vrx-allow: the modal's own route
      return VrxBackOffer(
        onBack: () => answer(null),
        child: VrxAsk(
          title: title,
          message: message,
          cancelLabel: cancelLabel,
          onCancel: () => answer(null),
          actions: [
            for (var i = 0; i < acts.length; i++) VrxModalAction(label: acts[i], onTap: () => answer(i)),
          ],
        ),
      );
    },
  ));
}

/// One named act in a modal.
class VrxModalAction {
  const VrxModalAction({required this.label, this.onTap});

  /// The act's own name ("Delete", "Forget"), never "OK".
  final String label;
  final VoidCallback? onTap;
}

/// The confirm: one destructive act or none.
class VrxConfirm extends StatelessWidget {
  // not const: the action-count assert is runtime-only
  // ignore: prefer_const_constructors_in_immutables
  VrxConfirm({
    super.key,
    required this.title,
    required this.message,
    required this.cancelLabel,
    this.act,
    this.onCancel,
  });

  /// The screen's own name for the question ("Delete alarm?").
  final String title;

  /// Says what will go, not whether you are sure.
  final String message;

  final String cancelLabel;
  final VoidCallback? onCancel;

  /// The act; its own name, shown filled.
  final VrxModalAction? act;

  @override
  Widget build(BuildContext context) {
    return VrxAsk(
      title: title,
      message: message,
      cancelLabel: cancelLabel,
      onCancel: onCancel,
      actions: act == null ? const [] : [act!],
    );
  }
}

/// The ask: Cancel plus up to two acts. One act sits beside Cancel in
/// a row; two stack in a column under it; the last act is filled.
/// Three acts is a menu, and a menu is a screen — the constructor
/// refuses it.
class VrxAsk extends StatelessWidget {
  // not const: .length is not const-evaluable; the contract check
  // runs at construction
  // ignore: prefer_const_constructors_in_immutables
  VrxAsk({
    super.key,
    required this.title,
    required this.message,
    required this.cancelLabel,
    this.onCancel,
    this.actions = const [],
  }) : assert(
            actions.length <= 2, 'three acts is a menu, and a menu is a screen');

  final String title;
  final String message;
  final String cancelLabel;
  final VoidCallback? onCancel;
  final List<VrxModalAction> actions;

  @override
  Widget build(BuildContext context) {
    final colors = VrxTheme.of(context);
    final s = ScaledSpacing.of(context);
    final cancel = VrxChip(
      label: cancelLabel,
      onTap: onCancel,
    );
    Widget acts;
    switch (actions.length) {
      case 0:
        acts = cancel;
      case 1:
        acts = Row(
          children: [
            Expanded(child: cancel),
            SizedBox(width: s.sm),
            Expanded(
              child: VrxChip(
                label: actions.single.label,
                filled: true,
                onTap: actions.single.onTap,
              ),
            ),
          ],
        );
      default:
        acts = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: double.infinity,
              child: cancel,
            ),
            SizedBox(height: s.sm),
            for (var i = 0; i < actions.length; i++) ...[
              SizedBox(
                width: double.infinity,
                child: VrxChip(
                  label: actions[i].label,
                  filled: i == actions.length - 1,
                  onTap: actions[i].onTap,
                ),
              ),
              if (i + 1 < actions.length) SizedBox(height: s.sm),
            ],
          ],
        );
    }
    return Center(
      child: Container(
        margin: EdgeInsets.all(s.xl),
        padding: EdgeInsets.all(s.md),
        decoration: BoxDecoration(
          color: colors.page,
          border: Border.all(color: colors.outline, width: Strokes.border),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: TypeRole.of(context, VrxTypeRole.title),
            ),
            SizedBox(height: s.sm),
            Text(
              message,
              style: TypeRole.of(context, VrxTypeRole.subtext),
            ),
            SizedBox(height: s.lg),
            acts,
          ],
        ),
      ),
    );
  }
}
