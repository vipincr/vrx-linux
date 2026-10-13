import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

/// A stand-in systemd that records the units it is asked to start and
/// stop, and refuses any other unit as polkit's rule would.
class _FakeSystemd extends DBusObject {
  _FakeSystemd() : super(DBusObjectPath('/org/freedesktop/systemd1'));

  final calls = <String>[];

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    final unit = call.values.first.asString();
    if (unit != 'vrx-usb-files.service') return DBusMethodErrorResponse.accessDenied('not authorised');
    calls.add('${call.name} $unit');
    return DBusMethodSuccessResponse([DBusObjectPath('/org/freedesktop/systemd1/job/1')]);
  }
}

void main() {
  test('USB: the port, the computer and the sharing read from sysfs and configfs', () async {
    final dir = await Directory.systemTemp.createTemp('vrx-usb');
    final udc = Directory('${dir.path}/udc');
    final gadget = '${dir.path}/gadget';
    // the reads never touch the bus; the client connects on first use
    final usb = LinuxUsbService(DBusClient(DBusAddress.unix(path: '${dir.path}/none')), udcRoot: udc.path, gadget: gadget);

    var state = await usb.watch().first;
    expect(state.present, isFalse, reason: 'no UDC: nothing to offer');

    await Directory('${udc.path}/fe980000.usb').create(recursive: true);
    final stateFile = File('${udc.path}/fe980000.usb/state');
    await stateFile.writeAsString('not attached\n');
    state = await usb.watch().first;
    expect((state.present, state.connected, state.sharing), (true, false, false));

    await stateFile.writeAsString('configured\n');
    await Directory('$gadget/functions/mass_storage.0').create(recursive: true);
    state = await usb.watch().first;
    expect((state.present, state.connected, state.sharing), (true, true, true));
    await dir.delete(recursive: true);
  });

  test('USB: sharing starts and stops vrx-usb-files.service', () async {
    final dir = await Directory.systemTemp.createTemp('vrx-usb-bus');
    final server = DBusServer();
    final address = await server.listenAddress(DBusAddress.unix(dir: dir));
    final serviceBus = DBusClient(address);
    final systemd = _FakeSystemd();
    await serviceBus.requestName('org.freedesktop.systemd1');
    await serviceBus.registerObject(systemd);
    final usb = LinuxUsbService(DBusClient(address));
    await usb.share(true);
    await usb.share(false);
    expect(systemd.calls, ['StartUnit vrx-usb-files.service', 'StopUnit vrx-usb-files.service']);
    await serviceBus.close();
    await server.close();
    await dir.delete(recursive: true);
    // as the time test: the dbus package's connection never completes on macOS
  }, skip: Platform.isLinux ? false : 'the dbus package supports Linux only');
}
