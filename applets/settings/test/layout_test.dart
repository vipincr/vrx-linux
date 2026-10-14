import 'dart:async';

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_check/vrx_check.dart';
import 'package:vrx_kit/vrx_kit.dart';

import 'package:settings_applet/main.dart';
import 'package:settings_applet/state.dart';

/// Every Settings screen holds on every display vrx drives (vrx_check).
void main() {
  SettingsModel model() => SettingsModel()
    // network time off: the set-the-time rows show
    ..time = const TimeState(zone: 'America/Argentina/Buenos_Aires', automatic: false, synced: false)
    ..timeLocales = const [
      TimeLocale(name: 'en_GB.utf8', timeFormat: '%T', dateFormat: '%d/%m/%y'),
      TimeLocale(name: 'en_US.utf8', timeFormat: '%r', dateFormat: '%m/%d/%Y'),
    ]
    ..timeLocale = 'en_US.utf8'
    ..battery = const Battery(name: 'BAT0', percent: 41, charging: true, volts: 3.912)
    ..usage = const DeviceUsage(memoryFreeMb: 1457, dataFreeMb: 11571, dataTotalMb: 13004, rootFreeMb: 388)
    ..network = const NetworkState(
      wifiPresent: true,
      wifiOn: true,
      ethernet: WiredLink(state: 'online', interface: 'eth0', address: '192.168.100.200', gateway: '192.168.100.1', nameservers: ['1.1.1.1']),
      networks: [
        WifiNetwork(id: 'a', name: 'Bench network 5GHz', strength: 80, secured: true, state: 'online', saved: true, address: '192.168.1.42'),
      ],
    )
    ..device = const DeviceState(
      name: 'Kitchen display',
      hostname: 'kitchen-display',
      version: '0.1.0074',
      model: 'Raspberry Pi Compute Module 4 Rev 1.1',
      serial: '10000000a1b2c3d4',
      memoryMb: 3796,
    )
    // the longest Device Link value: a connected phone's name
    ..bluetooth = const BluetoothState(present: true, on: true, devices: [
      BluetoothDevice(id: '/org/bluez/hci0/dev_1', name: 'Pixel 9 Pro XL of a long-named person', connected: true),
    ])
    ..dimming = VrxDimming.alpha
    ..display = const ScreenState(brightness: 40, lightOff: 600)
    // a colour panel drawing scheme 12, with 13 chosen: the longest Display
    ..runningScheme = 12
    ..values['vrx'] = {'scheme': '13', 'polarity': 'light'}
    // paired, the window open, a test device, two applets offered: every
    // Matter row (plan 0015)
    ..matter = MatterState(
        commissioned: true, fabrics: 2, window: true, windowUntil: DateTime(2026, 10, 14, 14, 5), attestation: 'test')
    ..matterApplets = const [MatterApplet(id: 'recorder', name: 'Recorder'), MatterApplet(id: 'clock', name: 'Clock')]
    ..canPowerOff = true
    ..supplyLow = true
    ..zones = ['America/Argentina/Buenos_Aires', 'Asia/Kolkata', 'Europe/London']
    ..declared = const [
      AppletSettingsDecl(id: 'clock', name: 'Clock', settings: [
        SettingDecl(key: 'clock_format', label: 'Time format', category: 'Clock', type: 'enum', defaultValue: '24h', options: ['24h', '12h']),
      ]),
      AppletSettingsDecl(id: 'recorder', name: 'Recorder', settings: [
        SettingDecl(key: 'sample_rate', label: 'Sample rate', category: 'Recorder', type: 'int', defaultValue: '44100'),
      ]),
    ];
  final screens = <String, SettingsModel Function()>{
    'categories': model,
    for (final c in SettingsCategory.values) c.name: () => model()..open = c,
    // the wired link's other states, beside Wi-Fi off
    'network, no cable': () => model()
      ..open = SettingsCategory.network
      ..network = const NetworkState(wifiPresent: true, wifiOn: false, networks: [], ethernet: WiredLink()),
    'network, ethernet connecting': () => model()
      ..open = SettingsCategory.network
      ..network = const NetworkState(wifiPresent: true, wifiOn: false, networks: [], ethernet: WiredLink(state: 'configuration', interface: 'eth0')),
    'setting entry': () => model()
      ..open = SettingsCategory.applets
      ..editingSetting = ('recorder', 'sample_rate'),
    'pair with a home app': () => model()
      ..open = SettingsCategory.matter
      ..pairing = true
      ..matterPayload = const MatterPayload(qr: 'MT:Y.K90AFN00KA0648G00', manual: '34970112332'),
    'pair with a home app, opening': () => model()
      ..open = SettingsCategory.matter
      ..pairing = true,
    // plan 0016 D11: the longest rows the update screen holds
    'software update': () => model()
      ..updatesAvailable = true
      ..open = SettingsCategory.device
      ..showingUpdate = true
      ..updateStatus = const UpdateStatus(running: '0.1.0074', last: UpdateOutcome.fellBack)
      ..updateOffers = const [
        UpdateOffer(file: 'vrx-bundle-vrxboard-cm4-0.1.0081.raucb', version: '0.1.0081'),
        UpdateOffer(file: 'vrx-bundle-vrxboard-cm5-0.1.0081.raucb', version: '0.1.0081', problem: 'machine'),
        UpdateOffer(file: 'manage-upload.raucb', version: '', problem: 'unsigned'),
      ],
    'software update, installed': () => model()
      ..updatesAvailable = true
      ..open = SettingsCategory.device
      ..showingUpdate = true
      ..updateStatus = const UpdateStatus(running: '0.1.0074', trial: true, last: UpdateOutcome.trial)
      ..updateOffers = const []
      ..updateInstalled = '0.1.0081',
    'software update, installing': () => model()
      ..updatesAvailable = true
      ..open = SettingsCategory.device
      ..showingUpdate = true
      ..updateInstalling = '0.1.0081',
    // plan 0019 D11: the longest rows USB devices holds, on a board with an
    // allow-list, an unswitched port and a low supply
    'usb devices': () => model()
      ..open = SettingsCategory.device
      ..showingUsb = true
      ..usbHost = _usb,
    'usb devices, empty': () => model()
      ..open = SettingsCategory.device
      ..showingUsb = true
      ..usbHost = const UsbHostState(ports: ['USB-A'], vbus: 'switched', overcurrent: 'none', policy: UsbPolicy.open),
    'usb devices, policy failed': () => model()
      ..open = SettingsCategory.device
      ..showingUsb = true
      ..usbHost = const UsbHostState(ports: ['USB-A'], vbus: 'unknown', overcurrent: 'reported', policy: UsbPolicy.failed, devices: [
        UsbDevice(port: '1-1.4', cls: UsbClass.other, id: '0bda:8153', authorized: false, blocked: true),
      ]),
    'device with usb devices': () => model()
      ..open = SettingsCategory.device
      ..usbPresent = true
      ..usbHost = _usb,
    'rename': () => model()
      ..open = SettingsCategory.device
      ..renaming = true,
    'zone': () => model()
      ..open = SettingsCategory.time
      ..pickingZone = true,
    'colour scheme': () => model()
      ..open = SettingsCategory.display
      ..pickingScheme = true,
    'time format': () => model()
      ..open = SettingsCategory.time
      ..pickingTimeFormat = true,
    'set the date': () => model()
      ..open = SettingsCategory.time
      ..settingTime = SettingTime.date,
    'set the time': () => model()
      ..open = SettingsCategory.time
      ..settingTime = SettingTime.time,
    // plan 0012 D13, D14: a board that offers both later steps, with the
    // longest values they take
    'display with sleep and deep sleep': () => model()
      ..open = SettingsCategory.display
      ..cascade = const VrxCascade(sleep: true, deep: true, wakeAlarm: true)
      ..display = const ScreenState(brightness: 40, lightOff: 600, sleepAfter: 1800, deepAfter: 7200),
    // plan 0012 D12: the longest names and values a ranking holds
    'battery use': () => model()
      ..energyAvailable = true
      ..open = SettingsCategory.power
      ..showingUse = true
      ..energy = _report,
    'battery use, not calibrated': () => model()
      ..energyAvailable = true
      ..open = SettingsCategory.power
      ..showingUse = true
      ..energy = const EnergyReport(calibrated: false, hours: 24, rows: [
        EnergyRow(key: 'assistant', name: 'Assistant', system: false, millijoules: null, cpuMs: 4800000, gpuMs: 600000, wakeups: 900, frontSeconds: 0, over: true),
      ]),
    'why it is awake': () => model()
      ..energyAvailable = true
      ..open = SettingsCategory.power
      ..showingAwake = true
      ..energy = _report
      ..awake = const AwakeReport(
        inhibitors: [AwakeInhibitor(what: 'idle', who: 'clock', why: 'an alarm or timer is ringing', mode: 'block', applet: 'clock')],
        running: ['clock', 'launcher', 'settings', 'shell', 'stt'],
        frozen: ['assistant', 'recorder', 'scripts', 'terminal', 'web'],
        wakeups: [('mmc1', 120), ('Goodix Capacitive TouchScreen', 42)],
        governor: 'schedutil',
        khz: 1500000,
        tempMilliC: 51200,
        supplyLow: true,
        screenOn: true,
      ),
  };
  // every setting every repo applet declares, as Settings > Applets shows
  // it: a new applet's labels are measured with no new test
  final repoDeclared = [
    for (final m in repoManifests())
      if (m.settings.isNotEmpty)
        AppletSettingsDecl(id: m.id, name: m.name, settings: [
          for (final s in m.settings)
            SettingDecl(key: s.key, label: s.label, category: m.name, type: s.type, defaultValue: s.defaultValue, options: s.options),
        ]),
  ];
  screens['applets in the repo'] = () => model()
    ..declared = repoDeclared
    ..open = SettingsCategory.applets;
  for (final display in allDisplays) {
    for (final s in screens.entries) {
      testWidgets('settings ${s.key} on ${display.name}', (tester) async {
        await expectCleanLayout(tester, SettingsApplet(s.value()), display: display);
      });
    }
    // plan 0020 D4: the Power off confirmation says what off means on this
    // board, each sentence on every display. vrx_check judges screens and
    // reads a modal over its screen as text over text, so the modal is
    // checked here for what can go wrong with a long sentence: it is shown
    // whole (no line cut off) and inside the display.
    for (final c in _offs.entries) {
      testWidgets('settings power off confirmation, ${c.key}, fits on ${display.name}', (tester) async {
        await loadVrxFonts();
        tester.view.physicalSize = Size(display.width, display.height);
        tester.view.devicePixelRatio = display.pixelRatio;
        addTearDown(tester.view.reset);
        // only the power rows, so Power off is on screen on the smallest panel
        final m = model()
          ..open = SettingsCategory.power
          ..supplyLow = null
          ..battery = null
          ..cascade = c.value;
        await mountApplet(tester, SettingsApplet(m), touch: display.touch);
        await settleMotion(tester);
        await tester.tap(find.text('Power off'));
        await settleMotion(tester);
        final message = find.text(powerOffMessage(c.value));
        expect(message, findsOneWidget);
        expect(tester.renderObject<RenderParagraph>(message).didExceedMaxLines, isFalse);
        final r = tester.getRect(message);
        final screen = Offset.zero & tester.view.physicalSize / tester.view.devicePixelRatio;
        expect(screen.contains(r.topLeft) && screen.contains(r.bottomRight - const Offset(1, 1)), isTrue,
            reason: '$r is outside $screen');
        expect(tester.takeException(), isNull);
      });
    }
    // D12 (plan 0013): stepping a choice changes the value under the
    // finger; the row is laid out for its widest choice, so it keeps its
    // size (a short "Never" and the longest step)
    testWidgets('settings display keeps its rows as Screen off after steps, on ${display.name}', (tester) async {
      final facts = StreamController<SettingsAction>();
      addTearDown(facts.close);
      await expectStable(
        tester,
        SettingsApplet(model()..open = SettingsCategory.display),
        display: display,
        actions: facts.stream,
        change: (t) async => facts.add(const SettingsFacts(screen: ScreenState(brightness: 40, lightOff: 0))),
      );
    });
  }
}

const _offs = {
  'standby, replug': VrxCascade(off: VrxPowerOff.standby, offWake: VrxOffWake.replug),
  'standby, button': VrxCascade(off: VrxPowerOff.standby, offWake: VrxOffWake.button),
  'halt': VrxCascade(),
};

const _usb = UsbHostState(ports: ['USB-A'], vbus: 'unswitched', overcurrent: 'none', policy: UsbPolicy.allowlist, allowNew: false, devices: [
  UsbDevice(port: '1-1', name: 'USB2.0 Hub', cls: UsbClass.hub, id: '05e3:0610', speed: '480'),
  UsbDevice(port: '1-1.2', name: 'Logitech USB Receiver for a Wireless Keyboard', cls: UsbClass.hid, id: '046d:c534', speed: '12'),
  UsbDevice(port: '1-1.3', name: 'SanDisk Cruzer Blade Ultra Flair', cls: UsbClass.storage, id: '0781:5567', speed: '480', mounts: [
    '/run/vrx/usb/1-1.3-p1',
  ]),
  UsbDevice(port: '1-1.4', name: 'Seagate Expansion Desk', cls: UsbClass.storage, id: '0bc2:3312', speed: '480'),
  UsbDevice(port: '1-1.5', name: 'Realtek USB 10/100/1000 LAN', cls: UsbClass.other, id: '0bda:8153', authorized: false, blocked: true),
]);

const _report = EnergyReport(calibrated: true, measured: '2026-10-14 with fnb58', hours: 24, rows: [
  EnergyRow(key: 'system:floor', name: 'Idle floor', system: true, millijoules: 98000000, cpuMs: 0, gpuMs: 0, wakeups: 0, frontSeconds: 0, over: false),
  EnergyRow(key: 'system:screen', name: 'Screen', system: true, millijoules: 31000000, cpuMs: 0, gpuMs: 0, wakeups: 0, frontSeconds: 0, over: false),
  EnergyRow(key: 'web', name: 'Web requests', system: false, millijoules: 2400000, cpuMs: 340000, gpuMs: 60000, wakeups: 7000, frontSeconds: 4800, over: true),
  EnergyRow(key: 'assistant', name: 'Assistant', system: false, millijoules: 1200, cpuMs: 1200, gpuMs: 0, wakeups: 12, frontSeconds: 0, over: false),
]);
