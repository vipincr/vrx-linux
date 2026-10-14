import 'package:vrx_kit/vrx_kit.dart';

/// Everything the applet reacts to: a signal, or facts from the world
/// carried as data (plan 0013 D1: the reducer is the only writer).
sealed class UsbAction {
  const UsbAction();

  static const init = UsbSignal.init;
}

enum UsbSignal implements UsbAction { init }

/// The port's state arrived, or a refusal (null fields: unchanged).
final class UsbFacts implements UsbAction {
  const UsbFacts({this.usb, this.error});

  final UsbState? usb;
  final Change<String?>? error;

  @override
  bool operator ==(Object other) => other is UsbFacts && other.usb == usb && other.error == error;

  @override
  int get hashCode => Object.hash(usb, error);

  @override
  String toString() => 'UsbFacts($usb, $error)';
}

/// What the screen says, and what its buttons do.
enum UsbOffer { none, share, stop }

class UsbView {
  const UsbView({required this.title, required this.message, required this.offer, this.error});

  final String title;
  final String message;
  final UsbOffer offer;
  final String? error;
}

/// The model: the port's state (UsbService) and the last refusal.
class UsbModel extends StoreModel<UsbState, UsbAction, UsbView> {
  UsbState? usb;
  String? error;

  @override
  UsbState get initial => const UsbState(present: false, connected: false, sharing: false);

  @override
  UsbAction get bootAction => UsbAction.init;

  @override
  UsbView reduce(UsbState state, UsbAction action) {
    if (action case UsbFacts(:final usb, error: final err)) {
      // a new reading of the port clears a refusal; a refusal is its own fact
      if (usb != null) {
        this.usb = usb;
        error = null;
      }
      if (err != null) error = err.value;
    }
    final u = usb;
    if (u == null) return const UsbView(title: 'USB', message: '…', offer: UsbOffer.none);
    if (!u.present) {
      return UsbView(title: 'USB', message: 'This device has no USB device port.', offer: UsbOffer.none, error: error);
    }
    if (u.sharing) {
      return UsbView(
        title: 'Sharing files',
        message: 'The computer sees a disk named VRX. Eject it on the computer before you stop sharing.',
        offer: UsbOffer.stop,
        error: error,
      );
    }
    if (u.connected) {
      return UsbView(
        title: 'Computer connected',
        message: 'Share files with it: the computer sees a 1 GB disk named VRX. The console stays on the port.',
        offer: UsbOffer.share,
        error: error,
      );
    }
    return UsbView(
      title: 'USB',
      message: 'Connect a computer to the USB-C port to share files with it. The console is on the port either way.',
      offer: UsbOffer.share,
      error: error,
    );
  }

  @override
  UsbState get snapshot => usb ?? initial;

  @override
  void restore(UsbState snapshot) => usb = snapshot;

  @override
  Object? get fingerprint => (usb, error);
}
