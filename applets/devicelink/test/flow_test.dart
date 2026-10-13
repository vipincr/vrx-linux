import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

import 'package:devicelink_applet/main.dart';
import 'package:devicelink_applet/state.dart';

/// A stand-in for connman and BlueZ behind the kit's BluetoothService:
/// it records what the applet asked and plays a phone's request.
class _FakeBluetooth implements BluetoothService {
  final calls = <String>[];
  Future<bool> Function(BluetoothPairing)? confirm;

  @override
  Stream<BluetoothState> watch() => const Stream.empty();

  @override
  Future<void> setOn(bool on) async => calls.add('setOn $on');

  @override
  Future<void> openPairing({required Future<bool> Function(BluetoothPairing request) confirm}) async {
    calls.add('openPairing');
    this.confirm = confirm;
  }

  @override
  Future<void> closePairing() async => calls.add('closePairing');

  @override
  Future<void> forget(String device) async => calls.add('forget $device');
}

void main() {
  late _FakeBluetooth fake;
  late StreamController<LinkAction> events;
  setUp(() {
    fake = _FakeBluetooth();
    events = StreamController<LinkAction>.broadcast();
    VrxSystem.install(bluetooth: fake);
  });
  tearDown(() => events.close());
  Widget host(LinkModel model) => AppletHost(applet: LinkApplet(model, events: events), actions: events.stream);

  testWidgets('pair a phone: the window opens, the passkey is shown, Pair answers BlueZ', (tester) async {
    final model = LinkModel()..bt = const BluetoothState(present: true, on: false, name: 'hi');
    await tester.pumpWidget(host(model));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pair a phone'));
    await tester.pumpAndSettle();
    expect(fake.calls, ['openPairing']);
    expect(find.text('Bluetooth is on now.'), findsOneWidget, reason: 'the radio was off: the applet says it turned it on');

    // BlueZ calls the agent's RequestConfirmation
    final answer = fake.confirm!(BluetoothPairing(device: '/org/bluez/hci0/dev_9', name: 'Pixel', passkey: 123456));
    await tester.pumpAndSettle();
    expect(find.text('Pair with Pixel?'), findsOneWidget);
    expect(find.text('123 456'), findsOneWidget);
    await tester.tap(find.text('Pair'));
    await tester.pumpAndSettle();
    expect(await answer, isTrue);
    expect(find.text('Pair with Pixel?'), findsNothing);
  });

  testWidgets('a request BlueZ cancels leaves the screen and answers no', (tester) async {
    final model = LinkModel()..bt = const BluetoothState(present: true, on: true, discoverable: true);
    await tester.pumpWidget(host(model));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Stop pairing'));
    await tester.pumpAndSettle();
    expect(fake.calls, ['closePairing']);
    // the window open again, and a request the phone then gives up on
    model.bt = const BluetoothState(present: true, on: true);
    events.add(LinkAction.factsChanged);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pair a phone'));
    await tester.pumpAndSettle();
    final request = BluetoothPairing(device: '/org/bluez/hci0/dev_9', name: 'Car');
    final answer = fake.confirm!(request);
    await tester.pumpAndSettle();
    expect(find.text('Pair with Car?'), findsOneWidget);
    expect(find.text('Pair only if you asked Car to pair just now.'), findsOneWidget);
    request.cancel();
    await tester.pumpAndSettle();
    expect(await answer, isFalse);
    expect(find.text('Pair with Car?'), findsNothing);
  });

  testWidgets('forget asks first, then calls RemoveDevice', (tester) async {
    const phone = BluetoothDevice(id: '/org/bluez/hci0/dev_1', name: 'Pixel');
    final model = LinkModel()..bt = const BluetoothState(present: true, on: true, devices: [phone]);
    await tester.pumpWidget(host(model));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pixel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Forget this phone'));
    await tester.pumpAndSettle();
    expect(find.text('Forget Pixel?'), findsOneWidget);
    expect(fake.calls, isEmpty, reason: 'nothing is forgotten before the answer');
    await tester.tap(find.text('Forget'));
    await tester.pumpAndSettle();
    expect(fake.calls, ['forget /org/bluez/hci0/dev_1']);
  });
}
