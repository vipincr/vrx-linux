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
    final labelStyle = TypeRole.of(context, VrxTypeRole.list);
    final scaler = MediaQuery.textScalerOf(context);
    double labelWidth(String text) {
      final tp = TextPainter(
        text: TextSpan(text: text, style: labelStyle),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final w = tp.width;
      tp.dispose();
      return w;
    }

    final labels = [cancelLabel, for (final a in actions) a.label];
    return LayoutBuilder(builder: (context, box) {
      // the client's width less the standard inset each side: never a
      // fixed dialog width a small panel cannot hold (the bench, disp28a:
      // a narrow box broke "Can|cel" and "Res|tart" and clipped them)
      final width = box.maxWidth - 2 * s.inset;
      final inner = width - 2 * s.md - 2 * Strokes.border;
      // a chip's label plus its own padding and frame
      final chipPad = 2 * s.sm + 2 * Strokes.hairline + 1;
      final widest = labels.map(labelWidth).reduce((x, y) => x > y ? x : y) + chipPad;
      // side by side only when one act and Cancel both fit whole in half
      // the row each; otherwise stacked, full width, Cancel first and the
      // act last
      final sideBySide = actions.length == 1 && widest <= (inner - s.sm) / 2;
      Widget chip(String label, VoidCallback? onTap, {bool filled = false}) =>
          VrxChip(label: label, filled: filled, onTap: onTap, fit: true);
      final Widget acts;
      if (actions.isEmpty) {
        acts = SizedBox(width: double.infinity, child: chip(cancelLabel, onCancel));
      } else if (sideBySide) {
        acts = Row(children: [
          Expanded(child: chip(cancelLabel, onCancel)),
          SizedBox(width: s.sm),
          Expanded(child: chip(actions.single.label, actions.single.onTap, filled: true)),
        ]);
      } else {
        acts = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          chip(cancelLabel, onCancel),
          for (var i = 0; i < actions.length; i++) ...[
            SizedBox(height: s.sm),
            chip(actions[i].label, actions[i].onTap, filled: i == actions.length - 1),
          ],
        ]);
      }
      return Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: box.maxHeight - 2 * s.inset),
          child: Container(
            width: width,
            padding: EdgeInsets.all(s.md),
            decoration: BoxDecoration(
              color: colors.page,
              border: Border.all(color: colors.outline, width: Strokes.border),
            ),
            // a message longer than the screen scrolls; the acts stay
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Text(title, style: TypeRole.of(context, VrxTypeRole.title)),
                      SizedBox(height: s.sm),
                      Text(message, style: TypeRole.of(context, VrxTypeRole.subtext)),
                    ]),
                  ),
                ),
                SizedBox(height: s.lg),
                acts,
              ],
            ),
          ),
        ),
      );
    });
  }
}
