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
    void act(void Function() change, SettingsAction action) {
      change();
      AppletScope.dispatch(context, action);
    }

    if (view.openCategory == null) {
      return _CategoryList(
        view: view,
        onOpen: (category) =>
            act(() => _model.openCategory(category), SettingsAction.categoryOpened),
      );
    }
    return _SettingList(
      view: view,
      onClose: () => act(_model.closeCategory, SettingsAction.categoryOpened),
      onCycle: (key) =>
          act(() => _model.changeValue(key, _model.nextValue(key)), SettingsAction.changed),
    );
  }
}

class _CategoryList extends StatelessWidget {
  const _CategoryList({required this.view, required this.onOpen});

  final SettingsView view;
  final void Function(String category) onOpen;

  @override
  Widget build(BuildContext context) {
    final categories = view.rows.map((r) => r.category).toSet().toList();
    return Scaffold(
      body: VrxList(children: [
        // Back leaves the applet: a trail pop, vrxhost's decision
        const VrxHeader(title: 'Settings', onBack: Nav.pop),
        for (final category in categories)
          VrxRow(
            label: category,
            value: '›',
            onTap: () => onOpen(category),
          ),
      ]),
    );
  }
}

class _SettingList extends StatelessWidget {
  const _SettingList({
    required this.view,
    required this.onClose,
    required this.onCycle,
  });

  final SettingsView view;
  final VoidCallback onClose;
  final void Function(String key) onCycle;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: VrxList(children: [
        VrxHeader(
          title: view.openCategory ?? '',
          // back within the applet: the category list
          onBack: onClose,
        ),
        for (final row in view.rows)
          VrxSettingRow(
            label: row.label,
            value: row.value,
            onTap: () => onCycle(row.key),
          ),
      ]),
    );
  }
}

void main() => runApplet(SettingsApplet());
