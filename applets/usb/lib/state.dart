import 'package:vrx_kit/vrx_kit.dart';

/// Everything the applet reacts to.
enum UsbAction { init, factsChanged, failed }

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
    if (action == UsbAction.factsChanged) error = null;
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
}
