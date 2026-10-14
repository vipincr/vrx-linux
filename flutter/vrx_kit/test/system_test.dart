import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrx_kit/vrx_kit.dart';

/// A stand-in timedated: holds a zone, refuses SetTimezone for "Mars/*"
/// the way timedated refuses an unauthorised caller.
class _FakeTimedate extends DBusObject {
  _FakeTimedate() : super(DBusObjectPath('/org/freedesktop/timedate1'));

  String zone = 'UTC';

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async =>
      DBusGetAllPropertiesResponse({
        'Timezone': DBusString(zone),
        'NTP': const DBusBoolean(true),
        'NTPSynchronized': const DBusBoolean(false),
      });

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    if (call.name == 'SetTimezone') {
      final wanted = call.values.first.asString();
      if (wanted.startsWith('Mars/')) {
        return DBusMethodErrorResponse.accessDenied('not authorised');
      }
      zone = wanted;
      await emitPropertiesChanged('org.freedesktop.timedate1',
          changedProperties: {'Timezone': DBusString(zone)});
      return DBusMethodSuccessResponse();
    }
    return DBusMethodErrorResponse.unknownMethod();
  }
}

void main() {
  // connman's replies as the bench CM4 gave them (0.1.0097, connmanctl
  // services ethernet_d83addb321f7_cable, 2026-10-15)
  DBusStruct tech(String type, {bool powered = true}) => DBusStruct([
        DBusObjectPath('/net/connman/technology/$type'),
        DBusDict.stringVariant({'Type': DBusString(type), 'Powered': DBusBoolean(powered)}),
      ]);
  DBusStruct service(String path, Map<String, DBusValue> p) =>
      DBusStruct([DBusObjectPath(path), DBusDict.stringVariant(p)]);
  final cable = service('/net/connman/service/ethernet_d83addb321f7_cable', {
    'Type': const DBusString('ethernet'),
    'State': const DBusString('ready'),
    'Name': const DBusString('Wired'),
    'Ethernet': DBusDict.stringVariant({
      'Method': const DBusString('auto'),
      'Interface': const DBusString('eth0'),
      'Address': const DBusString('D8:3A:DD:B3:21:F7'),
      'MTU': const DBusUint16(1500),
    }),
    'IPv4': DBusDict.stringVariant({
      'Method': const DBusString('dhcp'),
      'Address': const DBusString('10.10.10.8'),
      'Netmask': const DBusString('255.255.255.0'),
      'Gateway': const DBusString('10.10.10.1'),
    }),
    'Nameservers': DBusArray.string(['1.1.1.1']),
  });

  test('connman: the wired link with its address, gateway and DNS', () {
    final n = networkFromConnman([tech('ethernet'), tech('wifi', powered: false)], [cable]);
    expect(n.wired, isTrue);
    expect(n.ethernet!.interface, 'eth0');
    expect(n.ethernet!.address, '10.10.10.8');
    expect(n.ethernet!.netmask, '255.255.255.0');
    expect(n.ethernet!.gateway, '10.10.10.1');
    expect(n.ethernet!.nameservers, ['1.1.1.1']);
    expect(n.wifiPresent, isTrue);
    expect(n.wifiOn, isFalse);
  });

  test('connman: an interface with no cable, and a board with no Ethernet', () {
    // connman keeps the technology and drops the service without a carrier
    final unplugged = networkFromConnman([tech('ethernet')], const []);
    expect(unplugged.ethernet, isNotNull);
    expect(unplugged.ethernet!.state, '');
    expect(unplugged.wired, isFalse);
    final none = networkFromConnman([tech('wifi')], const []);
    expect(none.ethernet, isNull);
    expect(none.wired, isFalse);
  });

  test('connman: a link that is down carries no stale address', () {
    final down = service('/net/connman/service/ethernet_x_cable', {
      'Type': const DBusString('ethernet'),
      'State': const DBusString('failure'),
      'IPv4': DBusDict.stringVariant({'Address': const DBusString('10.10.10.8')}),
      'Nameservers': DBusArray.string(['1.1.1.1']),
    });
    final n = networkFromConnman([tech('ethernet')], [down]);
    expect(n.ethernet!.state, 'failure');
    expect(n.ethernet!.address, '');
    expect(n.ethernet!.nameservers, isEmpty);
  });

  test('connman: Wi-Fi and Ethernet up together keep their own addresses', () {
    final wifi = service('/net/connman/service/wifi_home', {
      'Type': const DBusString('wifi'),
      'Name': const DBusString('home'),
      'State': const DBusString('online'),
      'Strength': const DBusByte(70),
      'Security': DBusArray.string(['psk']),
      'Favorite': const DBusBoolean(true),
      'IPv4': DBusDict.stringVariant({'Address': const DBusString('192.168.1.42')}),
    });
    // a second wired link that is down does not hide the one that is up
    final adapter = service('/net/connman/service/ethernet_usb_cable', {
      'Type': const DBusString('ethernet'),
      'State': const DBusString('idle'),
    });
    final n = networkFromConnman([tech('ethernet'), tech('wifi')], [cable, wifi, adapter]);
    expect(n.connected!.address, '192.168.1.42');
    expect(n.ethernet!.address, '10.10.10.8');
    expect(n.wired, isTrue);
  });

  test('the network name follows the person name', () {
    expect(hostnameFor('Vipin\'s Clock'), 'vipin-s-clock');
    expect(hostnameFor('  --  '), 'vrx');
    expect(hostnameFor('a' * 80).length, 63);
  });

  test('time over D-Bus: live state, a change, and a refusal by name', () async {
    final dir = await Directory.systemTemp.createTemp('vrx-bus');
    final server = DBusServer();
    final address = await server.listenAddress(DBusAddress.unix(dir: dir));
    final serviceBus = DBusClient(address);
    final fake = _FakeTimedate();
    await serviceBus.requestName('org.freedesktop.timedate1');
    await serviceBus.registerObject(fake);

    final time = DBusTimeService(DBusClient(address));
    final states = StreamIterator(time.watch());
    expect(await states.moveNext(), isTrue);
    expect(states.current.zone, 'UTC');
    expect(states.current.automatic, isTrue);

    await time.setZone('Asia/Kolkata');
    expect(await states.moveNext(), isTrue);
    expect(states.current.zone, 'Asia/Kolkata');

    await expectLater(
      time.setZone('Mars/Olympus'),
      throwsA(isA<SystemError>().having((e) => e.denied, 'denied', isTrue)),
    );
    await states.cancel();
    await serviceBus.close();
    await server.close();
    // the dbus package speaks the bus protocol on Linux (and Windows);
    // on a developer's macOS host its connection never completes
  }, skip: Platform.isLinux ? false : 'the dbus package supports Linux only');
}
