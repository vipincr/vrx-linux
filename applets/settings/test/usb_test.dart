import 'package:flutter/material.dart' hide Intent;
import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

import 'package:settings_applet/state.dart';
import 'package:settings_applet/usb_devices.dart';

/// Settings > Device > USB devices (plan 0019 D11).
void main() {
  // the reduce budget times one action; warm the reducer and the rows in
  // this isolate first (store_test.dart says why)
  setUpAll(() {
    final warm = SettingsModel();
    for (final c in SettingsCategory.values) {
      warm.reduce(const SettingsState(open: null, pickingZone: false), SettingsGo(open: Change(c)));
    }
    warm
      ..reduce(const SettingsState(open: null, pickingZone: false), const SettingsFacts(usbHost: UsbHostState(ports: ['USB-A'])))
      ..reduce(const SettingsState(open: null, pickingZone: false), const SettingsGo(showingUsb: true))
      ..reduce(const SettingsState(open: null, pickingZone: false), SettingsAction.back);
  });

  const keyboard = UsbDevice(port: '1-1.2', name: 'Keyboard', cls: UsbClass.hid, speed: '12');
  const hub = UsbDevice(port: '1-1', name: 'Hub', cls: UsbClass.hub, speed: '480');
  const stick = UsbDevice(port: '1-1.3', name: 'Stick', cls: UsbClass.storage, speed: '480', mounts: ['/run/vrx/usb/1-1.3-p1']);
  const blocked = UsbDevice(port: '1-1.5', name: 'LAN', cls: UsbClass.other, authorized: false, blocked: true);
  const host = UsbHostState(ports: ['USB-A'], vbus: 'unswitched', overcurrent: 'none', policy: UsbPolicy.allowlist);

  test('offered only where the image declares a host port; hubs are not counted', () {
    final model = SettingsModel();
    final h = StoreHarness(model)
      ..dispatch(const SettingsFacts(device: DeviceState(name: 'Kitchen display', hostname: 'kitchen-display')))
      ..dispatch(const SettingsGo(open: Change(SettingsCategory.device)));
    Iterable<String> keys() => h.view.rows.map((r) => r.key);
    expect(keys(), isNot(contains('usb_devices')), reason: 'no ports: no row');
    h.dispatch(const SettingsGo(showingUsb: true));
    expect(model.showingUsb, isFalse, reason: 'no ports: the screen does not open');
    h.dispatch(const SettingsFacts(usbHost: host));
    String row() => h.view.rows.firstWhere((r) => r.key == 'usb_devices').value;
    expect(row(), 'None');
    h.dispatch(SettingsFacts(usbHost: UsbHostState(ports: host.ports, policy: host.policy, devices: const [hub, keyboard])));
    expect(row(), '1 device');
    h.dispatch(SettingsFacts(usbHost: UsbHostState(ports: host.ports, policy: host.policy, devices: const [hub, keyboard, stick])));
    expect(row(), '2 devices');
    h.dispatch(const SettingsFacts(usbHost: UsbHostState(ports: ['USB-A'], policy: UsbPolicy.failed)));
    expect(row(), 'Policy failed');
  });

  test('the screen opens over Device and Back leaves it (plan 0013 D2)', () {
    final model = SettingsModel();
    final h = StoreHarness(model)
      ..dispatch(const SettingsFacts(usbHost: host))
      ..dispatch(const SettingsGo(open: Change(SettingsCategory.device)))
      ..dispatch(const SettingsGo(showingUsb: true));
    expect((model.showingUsb, model.depth), (true, 2));
    h.dispatch(const SettingsFacts(usbHost: UsbHostState()));
    expect(model.showingUsb, isFalse, reason: 'the ports went: the screen goes');
    h
      ..dispatch(const SettingsFacts(usbHost: host))
      ..dispatch(const SettingsGo(showingUsb: true))
      ..dispatch(SettingsAction.back);
    expect((model.showingUsb, model.open), (false, SettingsCategory.device));
    h
      ..dispatch(const SettingsGo(showingUsb: true))
      ..verify(
        fresh: SettingsModel.new,
        probes: const [
          SettingsAction.back,
          SettingsGo(showingUsb: true),
          SettingsFacts(usbHost: UsbHostState()),
          SettingsFacts(usbHost: host),
          SettingsFacts(error: 'x'),
        ],
      );
  });

  Future<void> show(WidgetTester tester, UsbHostState state, {bool? supplyLow, void Function(UsbDevice)? eject, void Function(bool)? allow}) =>
      tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: UsbDevicesScreen(
            state: state,
            supplyLow: supplyLow,
            onEject: eject ?? (_) {},
            onAllowNew: allow ?? (_) {},
            onBack: () {},
          ),
        ),
      ));

  testWidgets('nothing plugged in says so, and an open image has no switch', (tester) async {
    await show(tester, const UsbHostState(ports: ['USB-A'], vbus: 'switched', overcurrent: 'none', policy: UsbPolicy.open));
    expect(find.text('Nothing is plugged in.'), findsOneWidget);
    expect(find.text('Allow new USB devices'), findsNothing);
    expect(find.text("The board switches the ports' power."), findsOneWidget);
    expect(find.text('An overload on a port is not reported.'), findsOneWidget);
  });

  testWidgets('a drive ejects, a blocked device says why, the switch flips', (tester) async {
    UsbDevice? ejected;
    bool? allowed;
    await show(
      tester,
      UsbHostState(ports: host.ports, vbus: host.vbus, overcurrent: host.overcurrent, policy: host.policy, devices: const [hub, keyboard, stick, blocked]),
      eject: (d) => ejected = d,
      allow: (on) => allowed = on,
    );
    expect(find.text('Blocked: this kind of device is not allowed here'), findsOneWidget);
    // the kit breaks a line after a slash (a zero-width space): match the start
    expect(find.textContaining('Keyboard or mouse · 12 Mb/'), findsOneWidget);
    await tester.tap(find.text('Eject'));
    expect(ejected, stick);
    await tester.tap(find.text('Allow new USB devices'));
    expect(allowed, isFalse, reason: 'on now, so a tap switches it off');
    expect(find.textContaining('can reset the board'), findsOneWidget, reason: 'unswitched and unprotected');
    expect(find.text('An overload on a port is not reported.'), findsNothing, reason: 'the unswitched sentence says it');
  });

  testWidgets('a failed policy is said, and a low supply with a device attached is blamed', (tester) async {
    await show(
      tester,
      const UsbHostState(ports: ['USB-A'], policy: UsbPolicy.failed, devices: [blocked]),
      supplyLow: true,
    );
    expect(find.textContaining('The USB policy failed'), findsOneWidget);
    expect(find.text('Blocked: the USB policy is not running'), findsOneWidget);
    expect(find.text('Allow new USB devices'), findsNothing);
    expect(find.text('Power is low. A USB device may be drawing too much.'), findsOneWidget);
  });

  test('a drive that cannot be read says so', () {
    const ext4 = UsbDevice(port: '1-1.4', cls: UsbClass.storage);
    expect(usbDeviceLabel(ext4), 'Drive');
    expect(usbDeviceDetail(ext4, UsbPolicy.allowlist), 'Not readable: only FAT and exFAT drives open here');
  });
}
