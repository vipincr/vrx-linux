import 'package:flutter/material.dart' hide Intent; // vrx's Intent
import 'package:vrx_kit/vrx_kit.dart';

import 'state.dart';

/// The settings applet: renders every applet's declared settings,
/// grouped by category; a change writes `/data/settings/<key>` (the
/// state IPC shape) and everyone who cares watches the file.
class SettingsApplet
    extends Applet<SettingsState, SettingsAction, SettingsView> {
  final _model = SettingsModel();

  @override
  SettingsState get initial => _model.initial;

  @override
  SettingsAction get bootAction => _model.bootAction;

  @override
  SettingsView reduce(SettingsState state, SettingsAction action) =>
      _model.reduce(state, action);

  @override
  SettingsState get snapshot => _model.snapshot;

  @override
  Widget build(BuildContext context, SettingsView view) {
    if (view.openCategory == null) {
      return _CategoryList(view: view);
    }
    return _SettingList(view: view);
  }
}

class _CategoryList extends StatelessWidget {
  const _CategoryList({required this.view});

  final SettingsView view;

  @override
  Widget build(BuildContext context) {
    final categories = view.rows.map((r) => r.category).toSet().toList();
    return Scaffold(
      body: ListView(
        padding: EdgeInsets.all(Spacing.md),
        children: [
          Text('Settings', style: TypeRole.title(context)),
          SizedBox(height: Spacing.md),
          for (final category in categories)
            ListTile(
              title: Text(category, style: TypeRole.list(context)),
              trailing: Icon(Icons.chevron_right),
              onTap: () => Intent.send('settings.category.open',
                  {'category': category}),
            ),
        ],
      ),
    );
  }
}

class _SettingList extends StatelessWidget {
  const _SettingList({required this.view});

  final SettingsView view;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListView(
        padding: EdgeInsets.all(Spacing.md),
        children: [
          Text(view.openCategory ?? '', style: TypeRole.title(context)),
          SizedBox(height: Spacing.md),
          for (final row in view.rows)
            ListTile(
              title: Text(row.label, style: TypeRole.list(context)),
              trailing: Text(row.value, style: TypeRole.value(context)),
              onTap: () => Intent.send(
                'settings.value.cycle',
                {'key': row.key},
              ),
            ),
        ],
      ),
    );
  }
}

void main() {
  runApp(const MaterialApp(home: Scaffold(body: SizedBox.shrink())));
}
