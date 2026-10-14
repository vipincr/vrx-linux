import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

import 'package:devicelink_applet/state.dart';

void main() {
  const phone = BluetoothDevice(id: '/org/bluez/hci0/dev_1', name: 'Pixel', connected: true);
  late LinkModel model;
  late StoreHarness<Object, LinkAction, LinkView> h;
  var clock = DateTime(2026, 10, 14, 14, 20).millisecondsSinceEpoch;
  void facts(BluetoothState b) => h.dispatch(LinkFacts(bt: b));
  LinkModel fresh() => LinkModel(now: () => clock);

  setUp(() {
    model = fresh();
    h = StoreHarness(model);
  });

  test('the status follows BlueZ and connman: none, off, on, paired, connected', () {
    h.assertView((v) => v.status.isEmpty, because: 'nothing read yet');
    facts(const BluetoothState(present: false, on: false));
    h.assertView((v) => !v.usable && v.status == 'This device has no Bluetooth.');
    facts(const BluetoothState(present: true, on: true, allowed: false));
    h.assertView((v) => !v.usable && v.status == VrxWords.notAllowed);
    facts(const BluetoothState(present: true, on: false));
    h.assertView((v) => v.usable && !v.on && v.status.contains('turns it on'));
    facts(const BluetoothState(present: true, on: true));
    h.assertView((v) => v.status == 'No phone is paired yet.');
    facts(const BluetoothState(present: true, on: true, devices: [phone]));
    h.assertView((v) => v.status == 'Connected to Pixel.');
  });

  test('the window: its end is said in the locale\'s form, and it closes when BlueZ times it out', () {
    facts(const BluetoothState(present: true, on: true, name: 'hi'));
    h.dispatch(LinkAction.pairingOpened);
    facts(const BluetoothState(present: true, on: true, discoverable: true, name: 'hi'));
    h.assertView((v) => v.pairing && v.pairDetail == 'Visible to phones until 14:23' && v.status.contains('choose hi'));
    expect(model.keepsScreenOn, isNotNull, reason: 'the person is busy on the phone, not this screen');
    h.dispatch(const LinkFacts(h24: false));
    h.assertView((v) => v.pairDetail == 'Visible to phones until 2:23 PM');
    // DiscoverableTimeout passed: BlueZ turned it off
    facts(const BluetoothState(present: true, on: true, name: 'hi'));
    h.assertView((v) => !v.pairing && v.pairDetail == null);
    expect(model.visibleUntil, isNull);
    expect(model.keepsScreenOn, isNull, reason: 'nothing to watch once the window is shut');
  });

  test('a request is a screen until answered; the passkey is grouped the way a phone shows it', () {
    facts(const BluetoothState(present: true, on: true, discoverable: true));
    bool? answered;
    h.dispatch(LinkAsked(BluetoothPairing(device: '/org/bluez/hci0/dev_2', name: 'iPhone', passkey: 42),
        (pair) => answered = pair));
    h.assertView((v) => v.screen == LinkScreen.asking && v.passkey == '000 042' && v.askingName == 'iPhone');
    expect(model.keepsScreenOn, 'a phone is asking to pair');
    model.answer!(true);
    h.dispatch(LinkAction.answered);
    expect(answered, isTrue);
    h.assertView((v) => v.screen == LinkScreen.main);
    expect(model.answer, isNull);
  });

  test('a device screen closes when the device is forgotten; a new fact clears a refusal', () {
    facts(const BluetoothState(present: true, on: true, devices: [phone]));
    h.dispatch(LinkOpenDevice(phone.id));
    h.assertView((v) => v.screen == LinkScreen.device && v.device?.name == 'Pixel');
    h.dispatch(const LinkFacts(error: Change('refused')));
    h.assertView((v) => v.error == 'refused');
    facts(const BluetoothState(present: true, on: true));
    h.assertView((v) => v.screen == LinkScreen.main && v.error == null);
    expect(model.showing, isNull);
    h.dispatch(LinkOpenDevice(phone.id));
    h.verify(fresh: fresh, probes: const [LinkAction.deviceClosed, LinkAction.pairingOpened, LinkAction.pairingClosed]);
    clock += 1;
  });
}
