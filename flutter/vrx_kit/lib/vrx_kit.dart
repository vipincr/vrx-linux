/// The vrx Flutter SDK. One import gives an applet the whole vrx
/// development experience: the store, the design system, navigation,
/// motion, and the IPC clients.
///
/// An applet is a store: a pure model (state, actions, a reducer, a
/// derived view model), its effects, and a view — joined by one loop
/// that is the only writer of the state.
library;

export 'src/applet.dart';
export 'src/bluetooth.dart';
export 'src/channel.dart';
export 'src/chat.dart';
export 'src/chrome.dart';
export 'src/components.dart';
export 'src/energy.dart';
export 'src/entry.dart';
export 'src/file.dart';
export 'src/host.dart';
export 'src/input.dart';
export 'src/intent.dart';
export 'src/keyboard.dart';
export 'src/locale.dart';
export 'src/metrics.dart';
export 'src/modals.dart';
export 'src/motion.dart';
export 'src/nav.dart';
export 'src/pickers.dart';
export 'src/power_supply.dart';
export 'src/qr.dart';
export 'src/scale.dart';
export 'src/screen.dart';
export 'src/screens.dart';
export 'src/settings.dart';
export 'src/shell.dart';
export 'src/slider.dart';
export 'src/store.dart';
export 'src/symbols.dart';
export 'src/system.dart';
export 'src/theme.dart';
export 'src/ticker.dart';
export 'src/time_format.dart';
export 'src/words.dart';
// the slot names applets may say; the display class and the tables stay
// the kit's (an applet never knows what panel it is on: plan 0009 D4,
// evrx-rt docs/13)
export 'src/ui_standard.g.dart' show VrxSlot;
