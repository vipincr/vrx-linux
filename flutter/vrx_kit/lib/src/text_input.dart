/// The on-screen keyboard as Flutter's text input control (plan 0013 D6).
/// vrx boards have no system input method; Flutter lets an app supply its
/// own ([TextInput.setInputControl]), so any [TextField] taking focus
/// asks for it and the keyboard comes up under the screen, the way a
/// phone's does. No applet places the keyboard itself.
///
/// It stays away while a physical keyboard types ([VrxHands.keys]), and,
/// in the default mode, whenever the compositor says a keyboard is
/// plugged in ([VrxInputFacts.keyboard], [VrxKeyboardMode.auto]);
/// Settings > Device can make it always show.
library;

import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'input.dart';
import 'keyboard.dart';
import 'screen.dart';

/// The text input control the applet root installs: it follows the
/// focused field's connection and edits through it.
class VrxTextInputControl with TextInputControl {
  /// A field has asked for the keyboard and still has it.
  final ValueNotifier<bool> visible = ValueNotifier(false);

  // what a field last asked for; applied at once when the tree may
  // rebuild, after the frame when it may not (a field detaches as it is
  // torn down, inside the build's finalize phase)
  bool _want = false;
  bool _pending = false;
  bool _disposed = false;

  void _setVisible(bool v) {
    _want = v;
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (_disposed) return;
    if (phase == SchedulerPhase.idle || phase == SchedulerPhase.postFrameCallbacks) {
      visible.value = v;
      return;
    }
    if (_pending) return;
    _pending = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _pending = false;
      if (!_disposed) visible.value = _want;
    });
    SchedulerBinding.instance.scheduleFrame();
  }

  TextInputClient? _client;
  TextInputConfiguration _config = const TextInputConfiguration();
  TextEditingValue _value = TextEditingValue.empty;

  /// The focused field takes several lines (Enter types a newline).
  bool get multiline => _config.inputType == TextInputType.multiline;

  @override
  void attach(TextInputClient client, TextInputConfiguration configuration) {
    _client = client;
    _config = configuration;
  }

  @override
  void detach(TextInputClient client) {
    if (_client != client) return;
    _client = null;
    _setVisible(false);
  }

  @override
  void updateConfig(TextInputConfiguration configuration) => _config = configuration;

  // a field that brings its own keys (Flutter's TextInputType.none: the
  // Scripts editor's terminal keyboard) gets none from here
  @override
  void show() => _setVisible(_config.inputType != TextInputType.none);

  @override
  void hide() => _setVisible(false);

  @override
  void setEditingState(TextEditingValue value) => _value = value;

  TextSelection get _selection =>
      _value.selection.isValid ? _value.selection : TextSelection.collapsed(offset: _value.text.length);

  void _set(TextEditingValue v) {
    _value = v;
    TextInput.updateEditingValue(v);
  }

  /// Type [text] over the selection.
  void type(String text) {
    final sel = _selection;
    _set(TextEditingValue(
      text: _value.text.replaceRange(sel.start, sel.end, text),
      selection: TextSelection.collapsed(offset: sel.start + text.length),
    ));
  }

  /// Delete the selection, or the character before the caret.
  void backspace() {
    final sel = _selection;
    if (sel.isCollapsed && sel.start == 0) return;
    final start = sel.isCollapsed ? sel.start - 1 : sel.start;
    _set(TextEditingValue(
      text: _value.text.replaceRange(start, sel.end, ''),
      selection: TextSelection.collapsed(offset: start),
    ));
  }

  /// Enter: a newline in a multi-line field, else the field's action
  /// (done, send, next), which is what its onSubmitted hears.
  void enter() {
    if (multiline) {
      type('\n');
    } else {
      _client?.performAction(_config.inputAction);
    }
  }

  void dispose() {
    _disposed = true;
    visible.dispose();
  }
}

/// The applet root's keyboard place (AppletHost installs it under the
/// strip): the screen above, the keyboard under it while a field has it.
class VrxKeyboardHost extends StatefulWidget {
  const VrxKeyboardHost({super.key, required this.child, this.settings});

  final Widget child;

  /// Where the keyboard mode and the input facts are read; the board's
  /// when null.
  final ScreenSettings? settings;

  @override
  State<VrxKeyboardHost> createState() => _VrxKeyboardHostState();
}

class _VrxKeyboardHostState extends State<VrxKeyboardHost> {
  final _control = VrxTextInputControl();
  late final ScreenSettings _settings = widget.settings ?? ScreenSettings();
  StreamSubscription<VrxInputFacts>? _facts;
  StreamSubscription<ScreenState>? _screen;
  VrxInputFacts _input = const VrxInputFacts();
  VrxKeyboardMode _mode = VrxKeyboardMode.auto;

  @override
  void initState() {
    super.initState();
    TextInput.setInputControl(_control);
    _facts = _settings.inputFacts().listen((f) {
      if (mounted) setState(() => _input = f);
    }, onError: (Object _) {});
    _screen = _settings.watch().listen((s) {
      if (mounted) setState(() => _mode = s.keyboard);
    }, onError: (Object _) {});
  }

  @override
  void dispose() {
    unawaited(_facts?.cancel());
    unawaited(_screen?.cancel());
    TextInput.restorePlatformInputControl();
    _control.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: _control.visible,
      builder: (context, visible, child) {
        final away = VrxHandsScope.of(context) == VrxHands.keys || (_mode == VrxKeyboardMode.auto && _input.keyboard);
        return Column(children: [
          Expanded(child: child!),
          if (visible && !away) VrxKeyboard(input: _control),
        ]);
      },
      child: widget.child,
    );
  }
}
