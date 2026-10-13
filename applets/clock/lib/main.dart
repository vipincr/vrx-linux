import 'package:flutter/material.dart' hide Intent; // vrx's Intent
import 'package:vrx_kit/vrx_kit.dart';

import 'state.dart';

/// The clock applet: the model plus its Flutter view.
class ClockApplet extends Applet<ClockState, ClockAction, ClockView> {
  ClockApplet({DateTime Function()? clock}) : _model = ClockModel(clock: clock);

  final ClockModel _model;

  @override
  ClockState get initial => _model.initial;

  @override
  ClockAction get bootAction => _model.bootAction;

  @override
  ClockView reduce(ClockState state, ClockAction action) =>
      _model.reduce(state, action);

  @override
  ClockState get snapshot => _model.snapshot;

  @override
  Widget build(BuildContext context, ClockView view) {
    final screen = view.ringing //
        ? _RingScreen(view: view)
        : _ClockFace(view: view);
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // Back is a trail pop: vrxhost decides what comes next
            const VrxHeader(title: 'Clock', onBack: Nav.pop),
            Expanded(child: screen),
          ],
        ),
      ),
    );
  }
}

class _ClockFace extends StatelessWidget {
  const _ClockFace({required this.view});

  final ClockView view;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: ScaledSpacing.of(context).lg),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // the face is the screen's width at most: a narrow portrait
          // panel fits the digits rather than clipping them
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              view.time,
              style: TypeRole.clock(context).copyWith(
                fontWeight: FontWeight.w300,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          SizedBox(height: ScaledSpacing.of(context).sm),
          Text(
            view.is24h ? '24-hour' : '12-hour',
            style: TypeRole.caption(context),
          ),
          SizedBox(height: ScaledSpacing.of(context).md),
          VrxChip(
            label: view.is24h ? '12-hour' : '24-hour',
            onTap: () =>
                AppletScope.dispatch(context, ClockAction.formatChanged),
          ),
        ],
      ),
    );
  }
}

class _RingScreen extends StatelessWidget {
  const _RingScreen({required this.view});

  final ClockView view;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text('Alarm', style: TypeRole.title(context)),
          Text(view.time, style: TypeRole.display(context)),
          const SizedBox(height: Spacing.lg),
          ElevatedButton(
            onPressed: () =>
                AppletScope.dispatch(context, ClockAction.snoozeTapped),
            child: const Text('Snooze'),
          ),
        ],
      ),
    );
  }
}

void main() {
  // the face follows the wall clock; a tick a second keeps the minute
  // exact without a timer per widget
  runApplet(
    ClockApplet(clock: DateTime.now),
    actions: Stream.periodic(const Duration(seconds: 1), (_) => ClockAction.tick),
  );
}
