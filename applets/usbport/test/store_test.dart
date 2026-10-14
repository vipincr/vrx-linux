import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

import 'package:usbport_applet/state.dart';

void main() {
  test('the screen follows the port: no port, no computer, a computer, sharing', () {
    final model = UsbModel();
    final h = StoreHarness(model);
    h.assertView((v) => v.offer == UsbOffer.none, because: 'nothing read yet');
    void facts(UsbState u) => h.dispatch(UsbFacts(usb: u));

    facts(const UsbState(present: false, connected: false, sharing: false));
    h.assertView((v) => v.offer == UsbOffer.none && v.message.contains('no USB device port'));
    facts(const UsbState(present: true, connected: false, sharing: false));
    h.assertView((v) => v.title == 'USB' && v.offer == UsbOffer.share);
    facts(const UsbState(present: true, connected: true, sharing: false));
    h.assertView((v) => v.title == 'Computer connected' && v.offer == UsbOffer.share);
    facts(const UsbState(present: true, connected: true, sharing: true));
    h.assertView((v) => v.title == 'Sharing files' && v.offer == UsbOffer.stop);
    h.dispatch(const UsbFacts(error: Change('refused')));
    h.assertView((v) => v.error == 'refused');
    facts(const UsbState(present: true, connected: true, sharing: true));
    h.assertView((v) => v.error == null, because: 'a new fact clears the refusal');
    h.verify(fresh: UsbModel.new, probes: const [UsbFacts(error: Change(null))]);
  });
}
