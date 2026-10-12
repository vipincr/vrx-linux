import 'package:flutter/material.dart' hide Intent; // vrx's Intent
import 'package:vrx_kit/vrx_kit.dart';

import 'state.dart';

/// The clock applet: the model plus its Flutter view.
class ClockApplet extends Applet<ClockState, ClockAction, ClockView> {
  final _model = ClockModel();

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
    return Scaffold(body: screen);
  }
}

class _ClockFace extends StatelessWidget {
  const _ClockFace({required this.view});

  final ClockView view;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(view.time, style: TypeRole.display(context)),
          SizedBox(height: Spacing.sm),
          Text(view.is24h ? '24-hour' : '12-hour', style: TypeRole.caption(context)),
          SizedBox(height: Spacing.md),
          OutlinedButton(
            // the settings store owns the format; the clock watches it
            onPressed: () => Intent.send('clock.format.cycle'),
            child: const Text('Toggle format'),
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
          SizedBox(height: Spacing.lg),
          ElevatedButton(
            onPressed: () => Intent.send('clock.alarm.snooze'),
            child: const Text('Snooze'),
          ),
        ],
      ),
    );
  }
}

void main() {
  // The flutter-vrx runtime hosts applets; this entry point exists so
  // the applet also runs under `flutter run` during development.
  runApp(const MaterialApp(home: Scaffold(body: SizedBox.shrink())));
}
